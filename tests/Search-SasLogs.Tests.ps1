<#
    Pester tests for Search-SasLogs.ps1.

    They run against samples/logs, so they need no SAS estate and no network.
    Run them with:  Invoke-Pester -Path .\tests
#>

BeforeAll {
    $script:Root      = Split-Path -Parent $PSScriptRoot
    $script:Script    = Join-Path $Root 'src\Search-SasLogs.ps1'
    $script:SampleDir = Join-Path $Root 'samples\logs'

    # -PassThru keeps results as objects; -NoProgress and 6> keep the run quiet.
    # Caller keys overwrite the defaults rather than splatting alongside them, so
    # -Path can be redirected at the fixture estate below.
    function Invoke-Search {
        param([hashtable]$Params = @{})
        $splat = @{ Path = $script:SampleDir; PassThru = $true; NoProgress = $true }
        foreach ($k in $Params.Keys) { $splat[$k] = $Params[$k] }
        & $script:Script @splat 6>$null
    }

    # Distinct file names a result set touched. Compared by membership and count
    # rather than by position, because Sort-Object is culture-aware and orders
    # 'MI_alpha_archive.log' before 'MI_alpha.log'.
    function Get-Names {
        param($Result)
        @($Result.File | Sort-Object -Unique)
    }

    # ---- fixture estate -----------------------------------------------------
    # samples/logs is deliberately .log-only, flat, sanitised and committed, so
    # it cannot express other extensions, sub-folders, fixed timestamps or a
    # non-UTF8 encoding. Those cases get a scratch estate, torn down in AfterAll.
    $script:Fixture = Join-Path ([System.IO.Path]::GetTempPath()) "saslogs_fx_$(New-Guid)"
    New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'sub')   -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'empty') -Force | Out-Null

    # Line numbers are load-bearing here: 'libname' sits on both the first and
    # the last line so each -ContextLines boundary is covered, line 4 carries
    # leading whitespace, and line 5 holds two keywords at once.
    Set-Content -LiteralPath (Join-Path $script:Fixture 'MI_alpha.log') -Value @(
        'libname stage "D:\data";'
        'ERROR: Library ALPHA does not exist.'
        'NOTE: Invalid data for open_dt in line 3 4-13.'
        '      NOTE: Missing values were generated.'
        'libname beta; proc sql; quit;'
    )
    Set-Content -LiteralPath (Join-Path $script:Fixture 'MI_alpha_archive.log') -Value 'ERROR: archived copy'
    Set-Content -LiteralPath (Join-Path $script:Fixture 'RECON_beta.log')       -Value 'WARNING: recon drift detected'
    Set-Content -LiteralPath (Join-Path $script:Fixture 'notes.txt')            -Value 'ERROR: not a log file'
    Set-Content -LiteralPath (Join-Path $script:Fixture 'weird.log1')           -Value 'ERROR: eight point three'
    Set-Content -LiteralPath (Join-Path $script:Fixture 'sub\MI_nested.log')    -Value 'ERROR: nested'

    # Built from a code point so this test file stays pure ASCII on disk — a
    # literal accent would be read differently by PS 5.1 and PS 7.
    $script:Accented = "caf$([char]0xE9)"
    [System.IO.File]::WriteAllText(
        (Join-Path $script:Fixture 'latin1.log'),
        "NOTE: total for $script:Accented bar$([Environment]::NewLine)",
        [System.Text.Encoding]::GetEncoding(28591))

    # Fixed timestamps, so -Since/-Until/-Newest assert against known values.
    @{
        'MI_alpha.log'         = [datetime]'2025-01-01'
        'MI_alpha_archive.log' = [datetime]'2025-02-01'
        'RECON_beta.log'       = [datetime]'2025-03-01'
        'latin1.log'           = [datetime]'2024-01-01'
        'notes.txt'            = [datetime]'2024-01-01'
        'weird.log1'           = [datetime]'2024-01-01'
    }.GetEnumerator() | ForEach-Object {
        (Get-Item -LiteralPath (Join-Path $script:Fixture $_.Key)).LastWriteTime = $_.Value
    }
}

AfterAll {
    if ($script:Fixture -and (Test-Path -LiteralPath $script:Fixture)) {
        Remove-Item -LiteralPath $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Search-SasLogs' {

    Context 'Preconditions' {
        It 'finds the script' {
            $script:Script | Should -Exist
        }
        It 'finds the sample logs' {
            (Get-ChildItem $script:SampleDir -Filter '*.log').Count | Should -BeGreaterThan 0
        }
        It 'parses without syntax errors' {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $script:Script, [ref]$null, [ref]$errors) | Out-Null
            $errors.Count | Should -Be 0
        }
    }

    Context 'Keyword search' {
        It 'finds a literal keyword and reports file and line' {
            $r = Invoke-Search @{ Keyword = 'libname' }
            $r | Should -Not -BeNullOrEmpty
            $r[0].File       | Should -Match '\.log$'
            $r[0].LineNumber | Should -BeGreaterThan 0
        }

        It 'treats keywords as literals unless -Regex is given' {
            # '^ERROR' is a regex that matches plenty, but as a literal it matches nothing.
            Invoke-Search @{ Keyword = '^ERROR' } | Should -BeNullOrEmpty
            Invoke-Search @{ Keyword = '^ERROR'; Regex = $true } | Should -Not -BeNullOrEmpty
        }

        It 'is case-insensitive by default and case-sensitive on request' {
            $insensitive = Invoke-Search @{ Keyword = 'LIBNAME' }
            $sensitive   = Invoke-Search @{ Keyword = 'LIBNAME'; CaseSensitive = $true }
            @($insensitive).Count | Should -BeGreaterThan @($sensitive).Count
        }

        It 'accepts several keywords and labels each hit with the rule that fired' {
            $r = Invoke-Search @{ Keyword = 'libname', 'proc sql' }
            ($r.Rule | Sort-Object -Unique) | Should -Contain 'libname'
        }
    }

    Context 'SAS issue scan' {
        BeforeAll { $script:Issues = Invoke-Search @{ SasIssues = $true } }

        It 'flags errors and warnings' {
            $script:Issues.Rule | Should -Contain 'Error'
            $script:Issues.Rule | Should -Contain 'Warning'
        }

        It 'flags the quieter signal <Rule>' -ForEach @(
            @{ Rule = 'Uninitialised var' }
            @{ Rule = 'Num->char convert' }
            @{ Rule = 'Char->num convert' }
            @{ Rule = 'Missing generated' }
            @{ Rule = 'Invalid data' }
            @{ Rule = 'Divide by zero' }
            @{ Rule = 'BY value repeats' }
            @{ Rule = 'Format truncation' }
            @{ Rule = 'Lost card' }
        ) {
            $script:Issues.Rule | Should -Contain $Rule
        }

        It 'reports only the first rule that matches a line' {
            # 'ERROR: Invalid argument ...' is reported as Error, not Invalid argument,
            # because ^ERROR matches earlier in the line. See docs/rules.md.
            $script:Issues.Rule | Should -Not -Contain 'Invalid argument'
        }

        It 'leaves a clean log alone' {
            $script:Issues.File | Should -Not -Contain 'RECON_clean_run.log'
        }

        It 'ignores -Keyword when -SasIssues is used' {
            # The two are separate parameter sets, so passing both must fail.
            { Invoke-Search @{ SasIssues = $true; Keyword = 'libname' } } | Should -Throw
        }
    }

    Context 'File selection' {
        It 'honours -Include' {
            $r = Invoke-Search @{ SasIssues = $true; Include = 'MI_*' }
            $r.File | ForEach-Object { $_ | Should -BeLike 'MI_*' }
        }

        It 'honours several -Include patterns' {
            $r = Invoke-Search @{ SasIssues = $true; Include = 'MI_*', 'RECON_*' }
            ($r.File | Sort-Object -Unique).Count | Should -BeGreaterThan 1
        }

        It 'honours -Exclude' {
            $r = Invoke-Search @{ SasIssues = $true; Exclude = '*archive*' }
            $r.File | Should -Not -Contain 'MI_daily_load_archive.log'
        }

        It 'honours -NameRegex' {
            $r = Invoke-Search @{ SasIssues = $true; NameRegex = '^RECON_' }
            $r.File | ForEach-Object { $_ | Should -BeLike 'RECON_*' }
        }

        It 'caps the file count with -MaxFiles' {
            $r = Invoke-Search @{ SasIssues = $true; MaxFiles = 1 }
            ($r.File | Sort-Object -Unique).Count | Should -Be 1
        }

        It 'caps hits per file with -MaxMatchesPerFile' {
            $r = Invoke-Search @{ SasIssues = $true; MaxMatchesPerFile = 2 }
            $r | Group-Object File | ForEach-Object { $_.Count | Should -BeLessOrEqual 2 }
        }

        It 'returns nothing when the window excludes every file' {
            $r = Invoke-Search @{ SasIssues = $true; Until = (Get-Date).AddYears(-50) } 3>$null
            $r | Should -BeNullOrEmpty
        }

        It 'rejects a folder that does not exist' {
            { & $script:Script -Path 'Z:\no\such\folder' -Keyword 'x' } | Should -Throw
        }
    }

    Context 'Context lines' {
        It 'captures surrounding lines when asked' {
            $r = Invoke-Search @{ Keyword = 'Division by zero'; ContextLines = 2 }
            $r[0].Before | Should -Not -BeNullOrEmpty
            $r[0].After  | Should -Not -BeNullOrEmpty
        }

        It 'leaves them empty by default' {
            $r = Invoke-Search @{ Keyword = 'Division by zero' }
            $r[0].Before | Should -BeNullOrEmpty
        }
    }

    Context 'CSV output' {
        BeforeAll {
            $script:CsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "saslogs_$(New-Guid).csv"
        }
        AfterAll {
            Remove-Item $script:CsvPath -ErrorAction SilentlyContinue
        }

        It 'writes a CSV with the expected columns' {
            & $script:Script -Path $script:SampleDir -SasIssues -CsvPath $script:CsvPath -NoProgress | Out-Null
            $script:CsvPath | Should -Exist

            $rows = Import-Csv $script:CsvPath
            $rows.Count | Should -BeGreaterThan 0
            $rows[0].PSObject.Properties.Name | Should -Be @(
                'File', 'LineNumber', 'Rule', 'Matched', 'Line', 'Before', 'After', 'FullPath', 'LogDate')
        }
    }

    Context 'Read-only guarantee' {
        It 'does not modify the log folder' {
            $before = Get-ChildItem $script:SampleDir -File |
                Select-Object Name, Length, LastWriteTime

            Invoke-Search @{ SasIssues = $true } | Out-Null

            $after = Get-ChildItem $script:SampleDir -File |
                Select-Object Name, Length, LastWriteTime

            ($after | ConvertTo-Json) | Should -Be ($before | ConvertTo-Json)
        }
    }

    # -------------------------------------------------------------------------
    # Everything below runs against the scratch fixture rather than samples/logs.
    # -------------------------------------------------------------------------

    Context 'Include pattern normalisation' {
        It 'treats a bare pattern as a prefix, not an exact name' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true; Include = 'MI_alpha' })
            $n.Count | Should -Be 2
            $n | Should -Contain 'MI_alpha.log'
            $n | Should -Contain 'MI_alpha_archive.log'
        }

        It 'expands bare patterns identically when several are given' {
            # Regression: expansion used to apply only to a lone pattern, so
            # adding a second bare pattern made the first one match nothing.
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Include = 'MI_alpha', 'RECON_beta' })
            $n.Count | Should -Be 3
            $n | Should -Contain 'MI_alpha.log'
            $n | Should -Contain 'MI_alpha_archive.log'
            $n | Should -Contain 'RECON_beta.log'
        }

        It 'gives a pattern the same result whether or not others accompany it' {
            $alone = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                                 Include = 'MI_alpha' })
            $joint = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                                 Include = 'MI_alpha', 'ZZZ_nothing' })
            $joint | Should -Be $alone
        }

        It 'uses a pattern verbatim when it carries both a wildcard and an extension' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Include = 'RECON_*.log' })
            $n | Should -Be @('RECON_beta.log')
        }

        It 'returns nothing when no name matches' {
            Invoke-Search @{ Path = $script:Fixture; SasIssues = $true; Include = 'ZZZ_*' } 3>$null |
                Should -BeNullOrEmpty
        }
    }

    Context 'Extension handling' {
        It 'sweeps only .log by default' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true })
            $n | Should -Not -Contain 'notes.txt'
        }

        It 'ignores a .log1 look-alike' {
            # The 8.3 short-name quirk the explicit re-check exists to guard.
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true })
            $n | Should -Not -Contain 'weird.log1'
        }

        It 'sweeps every file when -Extension is emptied' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true; Extension = '' })
            $n | Should -Contain 'notes.txt'
            $n | Should -Contain 'weird.log1'
        }

        It 'retargets the sweep at another extension on its own' {
            # This only works because the provider wildcard is derived from
            # -Extension; it used to need the -Filter parameter as well.
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true; Extension = '.txt' })
            $n | Should -Be @('notes.txt')
        }

        It 'no longer exposes -Filter' {
            { & $script:Script -Path $script:Fixture -SasIssues -Filter '*.log' -NoProgress } |
                Should -Throw
        }
    }

    Context 'Recursion' {
        It 'stays in the top folder by default' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true })
            $n | Should -Not -Contain 'MI_nested.log'
        }

        It 'descends into sub-folders with -Recurse' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true; Recurse = $true })
            $n | Should -Contain 'MI_nested.log'
        }
    }

    Context 'Date window and ordering' {
        It 'keeps only files inside a -Since/-Until window' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Since = [datetime]'2025-01-15'
                                             Until = [datetime]'2025-02-15' })
            $n | Should -Be @('MI_alpha_archive.log')
        }

        It 'honours -Since on its own' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Since = [datetime]'2025-02-15' })
            $n | Should -Be @('RECON_beta.log')
        }

        It 'takes the most recently written file with -Newest' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Newest = $true; MaxFiles = 1 })
            $n | Should -Be @('RECON_beta.log')
        }
    }

    Context 'Encoding' {
        It 'reads a wlatin1 log when told to' {
            $r = Invoke-Search @{ Path = $script:Fixture; Keyword = $script:Accented
                                  Encoding = 'Latin1'; Include = 'latin1*' }
            $r | Should -Not -BeNullOrEmpty
            $r[0].File | Should -Be 'latin1.log'
        }

        It 'silently misses the same text when decoded as UTF8' {
            # Documents the current default rather than endorsing it: mis-decoding
            # substitutes replacement characters instead of raising an error, so a
            # mangled log is indistinguishable from a clean one.
            Invoke-Search @{ Path = $script:Fixture; Keyword = $script:Accented
                             Encoding = 'UTF8'; Include = 'latin1*' } 3>$null |
                Should -BeNullOrEmpty
        }
    }

    Context 'Result shape' {
        BeforeAll {
            $script:Shape = Invoke-Search @{ Path = $script:Fixture; Keyword = 'ERROR: Library'
                                             Include = 'MI_alpha' }
        }

        It 'populates every advertised field' {
            $script:Shape[0].File       | Should -Be 'MI_alpha.log'
            $script:Shape[0].LineNumber | Should -Be 2
            $script:Shape[0].Rule       | Should -Be 'ERROR: Library'
            $script:Shape[0].Matched    | Should -Be 'ERROR: Library'
            $script:Shape[0].FullPath   | Should -Exist
            $script:Shape[0].LogDate    | Should -BeOfType [datetime]
        }

        It 'trims leading whitespace off the reported line' {
            $r = Invoke-Search @{ Path = $script:Fixture; Keyword = 'Missing values were generated'
                                  Include = 'MI_alpha' }
            $r[0].Line | Should -Be 'NOTE: Missing values were generated.'
        }

        It 'reports a line once even when two keywords match it' {
            $r = Invoke-Search @{ Path = $script:Fixture; Keyword = 'libname', 'proc sql'
                                  Include = 'MI_alpha' }
            @($r | Where-Object { $_.File -eq 'MI_alpha.log' -and $_.LineNumber -eq 5 }).Count |
                Should -Be 1
        }
    }

    Context 'Context line boundaries' {
        BeforeAll {
            $script:Edges = Invoke-Search @{ Path = $script:Fixture; Keyword = 'libname'
                                             Include = 'MI_alpha'; ContextLines = 2 }
        }

        It 'leaves Before empty for a match on the first line' {
            $first = $script:Edges | Where-Object LineNumber -eq 1
            $first.Before | Should -BeNullOrEmpty
            $first.After  | Should -Not -BeNullOrEmpty
        }

        It 'leaves After empty for a match on the last line' {
            $last = $script:Edges | Where-Object LineNumber -eq 5
            $last.After  | Should -BeNullOrEmpty
            $last.Before | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Exclude' {
        It 'honours several -Exclude patterns' {
            $n = Get-Names (Invoke-Search @{ Path = $script:Fixture; SasIssues = $true
                                             Exclude = '*archive*', '*beta*' })
            $n | Should -Be @('MI_alpha.log')
        }
    }

    Context 'Regex mode' {
        It 'labels each hit with the pattern that fired' {
            $r = Invoke-Search @{ Path = $script:Fixture; Keyword = '^ERROR'; Regex = $true
                                  Include = 'MI_alpha' }
            @($r).Count | Should -Be 2
            ($r.Rule | Sort-Object -Unique) | Should -Be @('^ERROR')
        }
    }

    Context 'CSV path creation' {
        BeforeAll {
            $script:CsvRoot   = Join-Path ([System.IO.Path]::GetTempPath()) "saslogs_csv_$(New-Guid)"
            $script:NestedCsv = Join-Path $script:CsvRoot 'deep\hits.csv'
        }
        AfterAll {
            Remove-Item -LiteralPath $script:CsvRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'creates the parent folder when it does not exist' {
            $script:CsvRoot | Should -Not -Exist
            & $script:Script -Path $script:Fixture -SasIssues -CsvPath $script:NestedCsv -NoProgress 6>$null |
                Out-Null
            $script:NestedCsv | Should -Exist
            (Import-Csv $script:NestedCsv).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Concurrent access' {
        BeforeAll {
            $script:Live = Join-Path ([System.IO.Path]::GetTempPath()) "saslogs_live_$(New-Guid)"
            New-Item -ItemType Directory -Path $script:Live -Force | Out-Null
        }
        AfterAll {
            Remove-Item -LiteralPath $script:Live -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'reads a log its writer still holds open' {
            # A SAS job keeps its log open for the life of the run. Opening with
            # FileShare.Read would fail here, which is what used to happen.
            $p  = Join-Path $script:Live 'inflight.log'
            $fs = [System.IO.FileStream]::new($p, [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $w  = [System.IO.StreamWriter]::new($fs)
            try {
                $w.WriteLine('ERROR: job still in flight'); $w.Flush()
                $r = Invoke-Search @{ Path = $script:Live; SasIssues = $true; Include = 'inflight' }
                $r.File | Should -Contain 'inflight.log'
            }
            finally { $w.Dispose(); $fs.Dispose() }
        }

        It 'releases the handle as soon as a capped read stops early' {
            # -MaxMatchesPerFile breaks out of the read loop. PowerShell does not
            # dispose an enumerator on break, so without an explicit finally the
            # log stays locked until the garbage collector runs. No GC here: the
            # delete has to succeed on its own.
            $p = Join-Path $script:Live 'capped.log'
            Set-Content -LiteralPath $p -Value (1..200 | ForEach-Object { "ERROR: problem $_" })

            Invoke-Search @{ Path = $script:Live; SasIssues = $true
                             Include = 'capped'; MaxMatchesPerFile = 2 } | Out-Null

            { Remove-Item -LiteralPath $p -ErrorAction Stop } | Should -Not -Throw
        }

        It 'skips a file locked exclusively and carries on with the rest' {
            $ok = Join-Path $script:Live 'readable.log'
            Set-Content -LiteralPath $ok -Value 'ERROR: readable'
            $fs = [System.IO.FileStream]::new((Join-Path $script:Live 'exclusive.log'),
                    [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
            try {
                $r = Invoke-Search @{ Path = $script:Live; SasIssues = $true
                                      Include = 'readable', 'exclusive' } 3>$null
                $r.File | Should -Contain 'readable.log'
                $r.File | Should -Not -Contain 'exclusive.log'
            }
            finally { $fs.Dispose() }
        }
    }

    Context 'Empty folder' {
        It 'warns and returns nothing' {
            Invoke-Search @{ Path = (Join-Path $script:Fixture 'empty'); SasIssues = $true } 3>$null |
                Should -BeNullOrEmpty
        }
    }
}
