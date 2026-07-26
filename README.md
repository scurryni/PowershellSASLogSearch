# SAS Log Search

A PowerShell script that searches a folder of SAS 9 logs for keywords, or scans them
for the standard SAS trouble signals, and reports the file and line number of every hit.

It is purely observational: logs are opened read-only and nothing is written back to
the log folder. It also stays out of everyone else's way — see
[Running against a live folder](#running-against-a-live-folder). Results go to the
console, a CSV, or the pipeline.

## Layout

| Path | Holds |
| --- | --- |
| `src/` | [`Search-SasLogs.ps1`](src/Search-SasLogs.ps1) — the script. |
| `samples/logs/` | Small sanitised SAS 9 logs covering every issue rule, for tests and demos. |
| `tests/` | Pester tests that run against `samples/logs`. No SAS estate needed. |
| `docs/` | [`rules.md`](docs/rules.md) — what each `-SasIssues` rule matches and why. |
| `output/` | Scratch space for CSV results. Git-ignored. |

`output/` and `*.csv` are ignored, as are `*.log` files outside `samples/logs/` — real
logs should never be committed.

## Usage

Scan a folder for the standard SAS problems:

```powershell
.\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues
```

Search for a keyword and write the hits to a CSV:

```powershell
.\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -Keyword 'libname' -CsvPath '.\output\hits.csv'
```

Trial run over the 200 most recent `MI_*` logs before committing to a full sweep:

```powershell
.\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues -Include 'MI_*' -MaxFiles 200 -Newest
```

Rank the noisiest job/rule combinations:

```powershell
.\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues -PassThru |
    Group-Object File, Rule | Sort-Object Count -Descending | Select-Object -First 20
```

Try any of these against `samples\logs` first — it is a working folder of real-shaped
logs, so you can see the output without touching the estate.

Full parameter documentation lives in the script's comment-based help:

```powershell
Get-Help .\src\Search-SasLogs.ps1 -Full
```

## Output columns

`File`, `LineNumber`, `Rule`, `Matched`, `Line`, `Before`, `After`, `FullPath`, `LogDate`.

`Rule` names the signal that fired — the keyword, or the SAS issue from
[docs/rules.md](docs/rules.md). `Before` and `After` are populated only when
`-ContextLines` is given.

## Tests

The tests need **Pester 5**. Windows ships with Pester 3, which cannot run them:

```powershell
Get-Module -ListAvailable Pester          # check what you have
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

Then:

```powershell
Invoke-Pester -Path .\tests
```

## Running against a live folder

Safe to point at a folder that jobs are still writing to.

Logs are opened read-only **and shared for writing and deletion**. While a file is
being read, another process can still append to it, rename it, move it or delete it.
A rotation task, a backup agent or a running SAS job will not hit a sharing error
because of this script. A log that is still being written gets scanned rather than
skipped — the default `FileShare.Read` that most PowerShell file reads use would
have locked it out in both directions.

Two consequences worth knowing:

- **A log read mid-write is read as far as it had got.** Anything written after the
  read passes is not seen, so a job that fails later can look clean. To sweep only
  settled logs, exclude anything touched recently:

  ```powershell
  .\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -SasIssues -Until (Get-Date).AddMinutes(-5)
  ```

- **File selection is a snapshot.** Files are enumerated and filtered first, then
  read. Anything arriving after the sweep starts is simply not in that run — no
  error, no warning. `LogDate` is the timestamp as at enumeration.

A file locked exclusively by another process is still skipped, with a warning and a
count in the summary line. An empty result and a skipped file look the same in the
output, so check the `(N file(s) unreadable)` suffix on a sweep you intend to trust.

## Notes on performance

All patterns compile into a single .NET regex and each file is streamed line by line,
so non-matching lines cost very little. File selection is narrowed by name, age or
count before any file is opened. `-ContextLines` switches to reading whole files into
memory, so leave it off for large sweeps.
