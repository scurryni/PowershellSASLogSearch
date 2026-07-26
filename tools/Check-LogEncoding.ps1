<#
.SYNOPSIS
    Reports the text encoding of a folder of .log files, so -Encoding can be set
    correctly before running Search-SasLogs.ps1.

.DESCRIPTION
    Search-SasLogs.ps1 defaults to -Encoding UTF8. Reading a wlatin1 log as UTF-8
    does not raise an error: the offending bytes are silently replaced, so a line
    containing an accent or a currency symbol quietly fails to match and the log
    looks clean. This script says which encoding a log actually uses, so that
    default can be confirmed or corrected before a sweep is trusted.

    The test is a strict decode. Any byte >= 0x80 means the file is not plain
    ASCII; those bytes are then fed to a UTF-8 decoder that throws on invalid
    sequences. Valid UTF-8 almost never occurs by accident in wlatin1 text, so a
    successful decode means UTF-8 and a failure means wlatin1. A byte-order mark
    is checked first, because it settles the question on its own.

    Purely observational, and shares files for writing and deletion exactly as
    Search-SasLogs.ps1 does, so it can be pointed at a live log folder.

.PARAMETER Path
    Folder containing the .log files.

.PARAMETER Include
    Filename wildcard, default '*.log'. Passed straight to the filesystem, so it
    is a plain pattern - unlike Search-SasLogs.ps1 there is no prefix expansion.

.PARAMETER Sample
    How many files to inspect, newest first. Default 25. Encoding is usually a
    property of the estate rather than the individual file, so a sample is
    normally enough; raise it if different job types write differently.

.PARAMETER MaxBytes
    Stop reading each file after this many bytes, default 1MB. A trailing
    partial character is held over rather than reported as invalid.

.EXAMPLE
    .\tools\Check-LogEncoding.ps1 -Path 'S:\SAS Logs' -Include 'FC_*.log' |
        Format-Table -AutoSize

.EXAMPLE
    # Just the distinct verdicts across the estate
    .\tools\Check-LogEncoding.ps1 -Path 'S:\SAS Logs' -Sample 500 |
        Group-Object Suggested | Select-Object Count, Name
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Path,

    [string]$Include = '*.log',
    [int]$Sample     = 25,
    [int]$MaxBytes   = 1MB
)

$ErrorActionPreference = 'Stop'

# Both throw rather than substituting, which is the whole point: a silent
# substitution is exactly the failure this script exists to catch.
$strictAscii = [System.Text.Encoding]::GetEncoding('us-ascii',
                 [System.Text.EncoderFallback]::ExceptionFallback,
                 [System.Text.DecoderFallback]::ExceptionFallback)
$strictUtf8  = [System.Text.UTF8Encoding]::new($false, $true)

Get-ChildItem -LiteralPath $Path -Filter $Include -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Sample |
    ForEach-Object {

        # Same permissive share mode as Search-SasLogs.ps1, so checking a folder
        # cannot block a job still writing its log, or a rotation task moving it.
        $fs = [System.IO.FileStream]::new($_.FullName, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $buf  = [byte[]]::new([math]::Min($fs.Length, $MaxBytes))
            $read = $fs.Read($buf, 0, $buf.Length)
        }
        finally { $fs.Dispose() }

        $bom =
            if     ($read -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { 'UTF8-BOM' }
            elseif ($read -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE)                       { 'UTF16-LE' }
            elseif ($read -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF)                       { 'UTF16-BE' }
            else                                                                                   { 'none' }

        # Native-speed checks. A PowerShell predicate per byte would crawl on a
        # log of any size.
        $isAscii = $true
        try { $null = $strictAscii.GetString($buf, 0, $read) } catch { $isAscii = $false }

        # flush:$false so a multi-byte character split by -MaxBytes is carried
        # over instead of counting as a decode failure.
        $isUtf8 = $true
        try { $null = $strictUtf8.GetDecoder().GetCharCount($buf, 0, $read, $false) }
        catch { $isUtf8 = $false }

        $suggested =
            if     ($bom -like 'UTF16*') { 'Unicode' }
            elseif ($isAscii)            { '(any)' }
            elseif ($isUtf8)             { 'UTF8' }
            else                         { 'Latin1' }

        [pscustomobject]@{
            Name      = $_.Name
            KB        = [math]::Round($_.Length / 1KB, 1)
            BOM       = $bom
            Endings   = if ([Array]::IndexOf($buf, [byte]13) -ge 0) { 'CRLF' } else { 'LF' }
            Encoding  = switch ($suggested) {
                            'Unicode' { 'UTF-16' }
                            '(any)'   { 'ASCII' }
                            'UTF8'    { 'UTF-8' }
                            'Latin1'  { 'ANSI / wlatin1' }
                        }
            Suggested = $suggested
        }
    }
