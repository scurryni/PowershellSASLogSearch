<#
.SYNOPSIS
    Searches a folder of SAS .log files for keywords and reports the file name
    and line number of every match.

.DESCRIPTION
    Purely observational: opens files read-only, writes nothing back to the log
    folder. Results print to the console, or go to a CSV at a location you choose.

    Built for large estates. All patterns are compiled into a single .NET regex
    and each file is streamed line by line, so a line that does not match costs
    almost nothing. File selection is narrowed by name, age or count before any
    file is opened.

.PARAMETER Path
    Folder containing the .log files.

.PARAMETER Keyword
    One or more strings to search for. Literal by default; use -Regex to treat
    them as regular expressions.

.PARAMETER SasIssues
    Ignores -Keyword and scans for the standard SAS trouble signals. The Rule
    column names which signal fired.

.PARAMETER Include
    Filename wildcard pattern(s), e.g. 'MI_*' or 'MI_*','RECON_*'.

    A pattern carrying no extension is treated as a prefix: -Extension is
    appended, and so is a trailing '*' if you did not supply one. So
    'MI_daily_load' finds MI_daily_load.log and MI_daily_load_archive.log alike.
    Give both a wildcard and an extension ('RECON_*.log') to have the pattern
    used verbatim instead.

    Every pattern is normalised the same way whether you pass one or several.
    A lone pattern is also pushed down to the filesystem provider as an
    optimisation, but the resulting set is identical either way.

.PARAMETER Exclude
    Filename wildcard pattern(s) to skip, e.g. '*_test*','*archive*'.

.PARAMETER NameRegex
    Regular expression matched against the filename, applied after -Include.

.PARAMETER Since
    Restrict to files whose LastWriteTime is at or after this point.

.PARAMETER Until
    Restrict to files whose LastWriteTime is at or before this point.

.PARAMETER MaxFiles
    Stop after this many files. Combine with -Newest for a representative
    trial run before committing to a full sweep.

.PARAMETER Newest
    Select the most recently written files rather than the first alphabetically.

.PARAMETER MaxMatchesPerFile
    Stop reading a file after this many hits. Guards against one pathological
    log flooding the results.

.PARAMETER Extension
    File extension to sweep, default '.log'. Drives both the wildcard handed to
    the filesystem and a re-check of each file afterwards — the re-check guards
    against the Windows 8.3 quirk where the wildcard '*.log' also returns
    '.log1' and '.logs'. Set to '' to sweep every file regardless of extension.

.PARAMETER Encoding
    Text encoding of the logs: UTF8 (default), Latin1, ASCII, Unicode, Default.

.PARAMETER Recurse
    Search sub-folders as well as the top level of -Path.

.PARAMETER CaseSensitive
    Match case exactly. Off by default.

.PARAMETER Regex
    Treat each -Keyword as a regular expression rather than a literal string.

.PARAMETER ContextLines
    Lines either side of the match to capture (default 0). Note this switches
    to reading whole files into memory rather than streaming.

.PARAMETER CsvPath
    Write results to this CSV. Parent folder is created if missing.

.PARAMETER PassThru
    Emit result objects to the pipeline instead of printing a table.

.PARAMETER NoProgress
    Suppress the progress bar.

.EXAMPLE
    .\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues -Include 'MI_*' -MaxFiles 200 -Newest

.EXAMPLE
    .\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -Keyword 'libname' -Include 'MI_*' -CsvPath 'C:\Temp\hits.csv'

.EXAMPLE
    .\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues -PassThru |
        Group-Object File, Rule | Sort-Object Count -Descending | Select-Object -First 20
#>

[CmdletBinding(DefaultParameterSetName = 'Keyword')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Path,

    [Parameter(Mandatory, Position = 1, ParameterSetName = 'Keyword')]
    [string[]]$Keyword,

    [Parameter(Mandatory, ParameterSetName = 'SasIssues')]
    [switch]$SasIssues,

    # ---- file selection -----------------------------------------------------
    [string[]]$Include,
    [string[]]$Exclude,
    [string]$NameRegex,
    [datetime]$Since,
    [datetime]$Until,
    [int]$MaxFiles,
    [switch]$Newest,
    [string]$Extension = '.log',
    [switch]$Recurse,

    # ---- matching -----------------------------------------------------------
    [switch]$CaseSensitive,
    [switch]$Regex,
    [ValidateSet('UTF8','Latin1','ASCII','Unicode','Default')]
    [string]$Encoding = 'UTF8',
    [int]$MaxMatchesPerFile = 0,

    [ValidateRange(0, 20)]
    [int]$ContextLines = 0,

    # ---- output -------------------------------------------------------------
    [string]$CsvPath,
    [switch]$PassThru,
    [switch]$NoProgress
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# 1. Build one compiled regex with a named group per rule, so the result can
#    report WHICH rule fired, not just the text it happened to match.
# ---------------------------------------------------------------------------
if ($SasIssues) {
    $ruleMap = [ordered]@{
        'Error'              = '^ERROR'
        'Warning'            = '^WARNING'
        'Uninitialised var'  = 'uninitialized'
        'Num->char convert'  = 'Numeric values have been converted to character'
        'Char->num convert'  = 'Character values have been converted to numeric'
        'BY value repeats'   = 'repeats of BY values'
        'Invalid data'       = 'Invalid data for'
        'Invalid argument'   = 'Invalid argument'
        'Missing generated'  = 'Missing values were generated'
        'Format truncation'  = 'W\.D format was too small'
        'Lost card'          = 'LOST CARD'
        'Divide by zero'     = 'Division by zero'
    }
    $searchLabel = 'SAS issue scan'
}
else {
    $ruleMap = [ordered]@{}
    foreach ($k in $Keyword) {
        # Escaping literals means combining them preserves literal meaning.
        $ruleMap[$k] = if ($Regex) { $k } else { [regex]::Escape($k) }
    }
    $searchLabel = ($Keyword -join ' | ')
}

$ruleNames = @($ruleMap.Keys)
$combined  = (0..($ruleNames.Count - 1) | ForEach-Object {
    "(?<r$_>$($ruleMap[$ruleNames[$_]]))"
}) -join '|'

$reOpts = [System.Text.RegularExpressions.RegexOptions]::Compiled
if (-not $CaseSensitive) {
    $reOpts = $reOpts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
}
$rx = [regex]::new($combined, $reOpts)

$enc = switch ($Encoding) {
    'UTF8'    { [System.Text.Encoding]::UTF8 }
    'Latin1'  { [System.Text.Encoding]::GetEncoding(28591) }
    'ASCII'   { [System.Text.Encoding]::ASCII }
    'Unicode' { [System.Text.Encoding]::Unicode }
    'Default' { [System.Text.Encoding]::Default }
}

# ---------------------------------------------------------------------------
# 2. Select the files
# ---------------------------------------------------------------------------
# A bare -Include is a prefix, not an exact name: 'MI_daily_load' is meant to
# find MI_daily_load_archive.log too. Normalise every pattern identically, so a
# pattern cannot change meaning depending on how many others accompany it.
function Expand-IncludePattern {
    param([string]$Pattern, [string]$Ext)

    # Both a wildcard and an extension means the caller was explicit: use as-is.
    if ($Pattern -match '\.[^.\\/*?]+$' -and $Pattern -match '[*?]') { return $Pattern }

    "$Pattern$(if ($Pattern.EndsWith('*')) { '' } else { '*' })$Ext"
}

$includePatterns = @(foreach ($p in $Include) { Expand-IncludePattern $p $Extension })

# Provider-level wildcard: the cheapest narrowing available, since it is applied
# before any file is opened. Derived from -Extension rather than exposed as its
# own parameter, so the two can never contradict each other. A lone -Include can
# be pushed down to the provider as well; several cannot, so they are matched in
# memory below. Either way the in-memory pass decides the final set.
$effectiveFilter = if     ($includePatterns.Count -eq 1) { $includePatterns[0] }
                   elseif ($Extension)                   { "*$Extension" }
                   else                                  { '*' }

$gciArgs = @{ LiteralPath = $Path; Filter = $effectiveFilter; File = $true }
if ($Recurse) { $gciArgs.Recurse = $true }

Write-Verbose "Enumerating '$Path' with filter '$effectiveFilter'"
$files = Get-ChildItem @gciArgs

# Windows matches 8.3 short names too, so the wildcard '*.log' can return
# '.log1' and '.logs'. Re-check the extension explicitly.
if ($Extension) {
    $files = $files | Where-Object { $_.Extension -eq $Extension }
}

if ($includePatterns) {
    $files = $files | Where-Object { $n = $_.Name; ($includePatterns | Where-Object { $n -like $_ }) }
}
if ($Exclude)   { $files = $files | Where-Object { $n = $_.Name; -not ($Exclude | Where-Object { $n -like $_ }) } }
if ($NameRegex) { $files = $files | Where-Object { $_.Name -match $NameRegex } }
if ($PSBoundParameters.ContainsKey('Since')) { $files = $files | Where-Object { $_.LastWriteTime -ge $Since } }
if ($PSBoundParameters.ContainsKey('Until')) { $files = $files | Where-Object { $_.LastWriteTime -le $Until } }

# Sort by recency when trimming, so -MaxFiles yields a representative sample
# rather than whichever job names sort first.
$files = @(if ($Newest) { $files | Sort-Object LastWriteTime -Descending }
           else         { $files | Sort-Object FullName })

$totalFound = $files.Count
if ($MaxFiles -gt 0 -and $files.Count -gt $MaxFiles) { $files = $files[0..($MaxFiles - 1)] }

if (-not $files) {
    Write-Warning "No files matched under '$Path'."
    return
}

$totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "Scanning $($files.Count) file(s), $totalMB MB, for: $searchLabel" -ForegroundColor Cyan
if ($MaxFiles -gt 0 -and $totalFound -gt $MaxFiles) {
    Write-Host "  (limited by -MaxFiles; $totalFound matched the name filters)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 3. Search
# ---------------------------------------------------------------------------
$results  = [System.Collections.Generic.List[object]]::new()
$skipped  = 0
$i        = 0

foreach ($f in $files) {
    $i++
    if (-not $NoProgress -and ($i -eq 1 -or $i % 50 -eq 0)) {
        $rate = $i / [math]::Max($sw.Elapsed.TotalSeconds, 0.1)
        $eta  = [timespan]::FromSeconds(($files.Count - $i) / [math]::Max($rate, 0.1))
        Write-Progress -Activity 'Searching SAS logs' `
            -Status "$i of $($files.Count)  |  $($results.Count) matches  |  ETA $($eta.ToString('hh\:mm\:ss'))" `
            -PercentComplete ([math]::Round(($i / $files.Count) * 100, 1))
    }

    try {
        # Streaming when no context is needed; whole-file read only when it is.
        $lines   = if ($ContextLines -gt 0) { [System.IO.File]::ReadAllLines($f.FullName, $enc) }
                   else                     { [System.IO.File]::ReadLines($f.FullName, $enc) }
        $lineNo  = 0
        $hits    = 0

        foreach ($line in $lines) {
            $lineNo++
            $m = $rx.Match($line)
            if (-not $m.Success) { continue }

            $rule = 'unknown'
            for ($g = 0; $g -lt $ruleNames.Count; $g++) {
                if ($m.Groups["r$g"].Success) { $rule = $ruleNames[$g]; break }
            }

            $before = ''; $after = ''
            if ($ContextLines -gt 0) {
                $lo = [math]::Max(0, $lineNo - 1 - $ContextLines)
                $hi = [math]::Min($lines.Count - 1, $lineNo - 1 + $ContextLines)
                if ($lineNo - 2 -ge $lo) { $before = ($lines[$lo..($lineNo - 2)]) -join "`n" }
                if ($hi -ge $lineNo)     { $after  = ($lines[$lineNo..$hi])       -join "`n" }
            }

            $results.Add([pscustomobject]@{
                File       = $f.Name
                LineNumber = $lineNo
                Rule       = $rule
                Matched    = $m.Value
                Line       = $line.Trim()
                Before     = $before
                After      = $after
                FullPath   = $f.FullName
                LogDate    = $f.LastWriteTime
            })

            $hits++
            if ($MaxMatchesPerFile -gt 0 -and $hits -ge $MaxMatchesPerFile) {
                Write-Verbose "'$($f.Name)': stopped at $MaxMatchesPerFile matches."
                break
            }
        }
    }
    catch {
        $skipped++
        Write-Warning "Skipped '$($f.Name)': $($_.Exception.Message)"
    }
}
if (-not $NoProgress) { Write-Progress -Activity 'Searching SAS logs' -Completed }

$sw.Stop()
$elapsed = $sw.Elapsed.ToString('hh\:mm\:ss')

if ($results.Count -eq 0) {
    Write-Host "No matches for: $searchLabel  (scanned $($files.Count) files in $elapsed)" -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# 4. Output
# ---------------------------------------------------------------------------
if ($CsvPath) {
    $dir = Split-Path -Parent $CsvPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $results | Select-Object File, LineNumber, Rule, Matched, Line, Before, After, FullPath, LogDate |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV written: $CsvPath" -ForegroundColor Green
}

if ($PassThru) { $results }
elseif (-not $CsvPath) {
    $results | Format-Table File, LineNumber, Rule, Line -AutoSize -Wrap | Out-Host
}

# Printed last so it appears below the table, not above it.
$summary = "$($results.Count) match(es) in $(($results.File | Select-Object -Unique).Count) of $($files.Count) file(s) - $elapsed"
if ($skipped) { $summary += "  ($skipped file(s) unreadable)" }
Write-Host $summary -ForegroundColor Cyan
