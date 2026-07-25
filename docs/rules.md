# The `-SasIssues` rules

`-SasIssues` scans for the signals below instead of a keyword. The `Rule` column in the
results names the one that fired. Patterns are case-insensitive unless `-CaseSensitive`
is given, and are defined in the `$ruleMap` block near the top of
[`src/Search-SasLogs.ps1`](../src/Search-SasLogs.ps1).

| Rule | Pattern | What it usually means |
| --- | --- | --- |
| `Error` | `^ERROR` | The step failed. Always worth reading. |
| `Warning` | `^WARNING` | The step ran but SAS was unhappy — often an incomplete data set. |
| `Uninitialised var` | `uninitialized` | A variable was referenced before it was set. Usually a typo in a name, or a merge that did not bring in the column you expected. |
| `Num->char convert` | `Numeric values have been converted to character` | Implicit conversion. Silent, and a common source of leading-space and format surprises. |
| `Char->num convert` | `Character values have been converted to numeric` | The reverse. Non-numeric text becomes missing. |
| `BY value repeats` | `repeats of BY values` | Duplicate BY keys in a merge — the classic cause of a many-to-many blow-up. |
| `Invalid data` | `Invalid data for` | An input value did not fit its informat. The variable is set to missing. |
| `Invalid argument` | `Invalid argument` | A function got something it could not use. See the shadowing note below. |
| `Missing generated` | `Missing values were generated` | Arithmetic on missing values. Fine if expected, a bug if not. |
| `Format truncation` | `W\.D format was too small` | A number did not fit its format, so the printed value may be shifted. |
| `Lost card` | `LOST CARD` | Inline input ran out mid-record — the data does not match the INPUT statement. |
| `Divide by zero` | `Division by zero` | The result was set to missing. |

## One rule per line

Each line is reported once, under the **first** rule that matches earliest in the line.
`^ERROR` and `^WARNING` anchor at position 0, so they win against anything that appears
later in the same line.

In practice this means `Invalid argument` almost never fires on its own, because SAS
emits it as:

```
ERROR: Invalid argument to function INPUT at line 5 column 25.
```

which is reported as `Error`. To find those specifically, search for the text directly:

```powershell
.\src\Search-SasLogs.ps1 -Path 'D:\SAS Logs' -Keyword 'Invalid argument'
```

The same applies to any signal SAS prefixes with `ERROR:` or `WARNING:`. The rules are
most useful for the quieter `NOTE:` lines, which are easy to miss by eye and rarely
fail a job outright.

## Adding a rule

Add an entry to `$ruleMap`. The key becomes the `Rule` label, the value is a regex
fragment that gets wrapped in a named group and combined with the rest:

```powershell
'Merge overwrite' = 'MERGE statement has more than one data set with repeats'
```

Then add a line that triggers it to a file in `samples/logs/`, and a case to the
issue-scan test in [`tests/Search-SasLogs.Tests.ps1`](../tests/Search-SasLogs.Tests.ps1).
Put it above `Error`/`Warning` in the map only if you want it to win against them —
order decides ties at the same position, and the anchored rules match at position 0.
