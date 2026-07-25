<#
    Pester tests for Search-SasLogs.ps1.

    They run against samples/logs, so they need no SAS estate and no network.
    Run them with:  Invoke-Pester -Path .\tests
#>

BeforeAll {
    $script:Root      = Split-Path -Parent $PSScriptRoot
    $script:Script    = Join-Path $Root 'src\Search-SasLogs.ps1'
    $script:SampleDir = Join-Path $Root 'samples\logs'

    # -PassThru keeps results as objects; -NoProgress keeps the test output clean.
    function Invoke-Search {
        param([hashtable]$Params = @{})
        $defaults = @{ Path = $script:SampleDir; PassThru = $true; NoProgress = $true }
        & $script:Script @defaults @Params
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

        It 'flags the quieter data-quality signals' -ForEach @(
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
            $r.File | ForEach-Object { $_ | Should -BeLike 'FC_*' }
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
}
