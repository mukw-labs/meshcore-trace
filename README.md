# MeshCore Trace Analysis Scripts

Cross-platform scripts for running repeated `meshcli trace` checks against a list of MeshCore paths and saving clean results for later analysis.

## What This Repository Includes

- `meshcore-trace.sh` for Linux shells
- `meshcore-trace.ps1` for Windows PowerShell
- `paths.example.txt` as the template for your path list
- Timestamped output files written to the project root by default

## What The Scripts Do

For each configured path, the scripts:

1. Capture a startup snapshot of the companion radio settings
2. Run `meshcli trace <path>` multiple times
3. Strip ANSI color codes from the output
4. Mark each attempt as `OK` or `FAIL`
5. Extract SNR values from the last trace line when available
6. Save a timestamped CSV file and a plain-text summary file

This is useful for comparing path reliability, spotting unstable hops, and collecting repeatable trace data before deeper analysis.

## Prerequisites

- Python 3.9 or newer
- Git
- MeshCore CLI installed and available as `meshcli` in your `PATH`
- Access to the nodes or paths you want to test
- One of:
  - Linux with `bash`, `sed`, `grep`, `awk`
  - Windows with PowerShell 5.1 or newer

## Linux Setup

### Install MeshCore CLI

```bash
python3 -m pip install --user pipx
python3 -m pipx ensurepath
pipx install meshcore-cli
```

If `pipx` is not available in the current shell after `ensurepath`, open a new terminal and run:

```bash
pipx install meshcore-cli
```

### Clone This Repository

```bash
git clone https://github.com/mukw-labs/meshcore-trace.git
cd meshcore-trace
```

### Create Your Path File

```bash
cp paths.example.txt paths.txt
```

Then edit your local `paths.txt` using `paths.example.txt` as the template.

Example contents:

```txt
64
64,4d,64
64,4d,4a,4d,64
```

Rules:

- One path per line
- Blank lines are ignored
- Lines beginning with `#` are treated as comments

### Run

Make the script executable once:

```bash
chmod +x meshcore-trace.sh
```

Run with defaults:

```bash
./meshcore-trace.sh
```

Run with custom settings:

```bash
./meshcore-trace.sh --runs 20 --delay 3 --path-file ./paths.txt --output-dir .
```

### Troubleshooting

If `meshcli` installation or BLE setup gives you trouble, check the upstream MeshCore CLI documentation:

- MeshCore CLI repository: https://github.com/meshcore-dev/meshcore-cli
- MeshCore CLI README: https://github.com/meshcore-dev/meshcore-cli/blob/main/README.md

## Windows Setup

### Install MeshCore CLI

```powershell
py -m pip install --user pipx
py -m pipx ensurepath
pipx install meshcore-cli
```

If `pipx` is not available in the current shell after `ensurepath`, open a new PowerShell window and run:

```powershell
pipx install meshcore-cli
```

### Clone This Repository

```powershell
git clone https://github.com/mukw-labs/meshcore-trace.git
cd meshcore-trace
```

### Create Your Path File

```powershell
Copy-Item .\paths.example.txt .\paths.txt
```

Then edit your local `paths.txt` using `paths.example.txt` as the template.

### Run

Run with defaults:

```powershell
powershell -ExecutionPolicy Bypass -File .\meshcore-trace.ps1
```

Run with custom settings:

```powershell
powershell -ExecutionPolicy Bypass -File .\meshcore-trace.ps1 -Runs 20 -DelaySeconds 3 -PathFile .\paths.txt -OutputDir .
```

If PowerShell blocks script execution in your environment, open a shell with the appropriate execution policy for your machine or run the command above with `-ExecutionPolicy Bypass`.

### Troubleshooting

If `meshcli` installation or device setup gives you trouble, check the upstream MeshCore CLI documentation:

- MeshCore CLI repository: https://github.com/meshcore-dev/meshcore-cli
- MeshCore CLI README: https://github.com/meshcore-dev/meshcore-cli/blob/main/README.md

## Output Files

Each run creates two files in the current project directory by default:

- `meshcore-trace-YYYY-MM-DD_HH-MM-SS.csv`
- `meshcore-trace-YYYY-MM-DD_HH-MM-SS-summary.txt`

The summary file starts with a best-effort `meshcli infos` snapshot, including radio values such as frequency, bandwidth, spreading factor, and coding rate when the companion returns them. Each path summary line also includes the average SNR per hop position across successful runs.

For stable scripted output, both scripts call `meshcli` with `-c off`. They do not use `-C`, because classic prompt mode is only relevant for interactive terminal use.

The CSV columns are:

```txt
date,time,radio_settings,label,path,run,status,snr_values
```

Example CSV rows:

```txt
2026-04-23,19:45:01,"915.8,250.0,11,5",PATH1,"64",1,OK,"-12.4,-14.1"
2026-04-23,19:45:03,"915.8,250.0,11,5",PATH1,"64",2,FAIL,""
```

## AI Comparison Prompt

If you want to compare two CSV outputs from this script in an AI chat, you can attach both files and paste this prompt:

```txt
Compare these two MeshCore trace CSV files and summarize the differences.

Work from facts in the CSV data only. Do not guess causes, do not invent missing values, and do not describe anything as better unless the data clearly supports it.

Each CSV row has this structure:
date,time,radio_settings,label,path,run,status,snr_values

Important rules for interpretation:
- `status` is either `OK` or `FAIL`
- `radio_settings` is a single comma-separated field such as `915.8,250.0,11,5`
- `snr_values` is a comma-separated list of hop SNR values for successful rows
- failed rows usually have an empty `snr_values`
- success rate must be calculated from all rows, not just successful rows
- average SNR values must be calculated from successful rows only
- the first SNR value is from the companion to the first hop
- the last SNR value is from the final hop back to the companion
- any SNR values between the first and last are between repeaters in the middle of the path
- if `radio_settings` differ between files or between paths, note that SNR values may not be directly comparable
- success rates, failure counts, and consistency of success/failure patterns are still comparable even when `radio_settings` differ

Please produce the result in this structure:

1. Overall summary
- Give a short plain-English comparison of file A vs file B
- State the total runs, total successes, total failures, and success rate for each file

2. Radio settings
- Show the distinct `radio_settings` values found in each file
- State whether the radio settings match or differ
- If radio settings differ, explicitly warn that SNR comparisons may be limited

3. Per-path comparison
- Compare results by `path`
- For each path, report:
  - total runs in file A and file B
  - successes and failures in file A and file B
  - success rate in file A and file B
  - average hop SNR values in file A and file B, aligned by hop position
- If a path exists in one file but not the other, say that clearly

4. Notable factual differences
- Highlight the biggest observed differences in success rate
- Highlight any clear differences in hop SNR values, but only treat them as directly comparable when radio settings match
- Highlight any paths with consistently poor or consistently strong success rates, but only if the CSV data clearly shows that

5. Data caveats
- Mention small sample sizes, missing paths, or rows without SNR values if relevant
- If the files cannot be compared fairly for some reason, say so clearly

Formatting requirements:
- Use a small markdown table for the per-path comparison if possible
- Round success rates to 1 decimal place
- Round average SNR values to 2 decimal places
- Keep the answer concise and analytical
- Do not speculate about RF causes, firmware issues, hardware faults, or environmental reasons unless they are directly stated in the data
```
