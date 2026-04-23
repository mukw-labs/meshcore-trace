param(
    [string]$PathFile = (Join-Path $PSScriptRoot "paths.txt"),
    [int]$Runs = 10,
    [int]$DelaySeconds = 2,
    [string]$OutputDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$MeshCliBaseArgs = @("-c", "off")
$CompanionRadioFreq = ""
$CompanionRadioBw = ""
$CompanionRadioSf = ""
$CompanionRadioCr = ""

function Get-CleanOutput {
    param([string]$RawText)

    return ($RawText -replace '\x1b\[[0-9;?]*[A-Za-z]', '')
}

function Invoke-MeshCli {
    param([string[]]$Arguments)

    return ((& meshcli @MeshCliBaseArgs @Arguments 2>&1 | ForEach-Object { $_.ToString() }) -join "`n")
}

function Get-JsonBlock {
    param([string]$RawText)

    $Lines = $RawText -split "`r?`n"
    $StartIndex = -1

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\{') {
            $StartIndex = $i
            break
        }
    }

    if ($StartIndex -lt 0) {
        return $null
    }

    return ($Lines[$StartIndex..($Lines.Count - 1)] -join "`n")
}

function Write-CompanionSettingsSnapshot {
    $RawOutput = Get-CleanOutput -RawText (Invoke-MeshCli -Arguments @("-j", "infos"))
    $JsonBlock = Get-JsonBlock -RawText $RawOutput

    Add-Content -LiteralPath $SummaryFile -Value "Companion settings snapshot:"

    if ($JsonBlock) {
        try {
            $Info = $JsonBlock | ConvertFrom-Json
            if ($null -ne $Info.radio_freq) { $script:CompanionRadioFreq = [string]$Info.radio_freq; Add-Content -LiteralPath $SummaryFile -Value "radio_freq: $($Info.radio_freq)" }
            if ($null -ne $Info.radio_bw) { $script:CompanionRadioBw = [string]$Info.radio_bw; Add-Content -LiteralPath $SummaryFile -Value "radio_bw: $($Info.radio_bw)" }
            if ($null -ne $Info.radio_sf) { $script:CompanionRadioSf = [string]$Info.radio_sf; Add-Content -LiteralPath $SummaryFile -Value "radio_sf: $($Info.radio_sf)" }
            if ($null -ne $Info.radio_cr) { $script:CompanionRadioCr = [string]$Info.radio_cr; Add-Content -LiteralPath $SummaryFile -Value "radio_cr: $($Info.radio_cr)" }
            Add-Content -LiteralPath $SummaryFile -Value ""

            Write-Host "Companion settings: freq=$($Info.radio_freq), bw=$($Info.radio_bw), sf=$($Info.radio_sf), cr=$($Info.radio_cr)"
        }
        catch {
            Add-Content -LiteralPath $SummaryFile -Value "unavailable"
            Add-Content -LiteralPath $SummaryFile -Value ""

            Write-Host "Companion settings: unavailable"
        }
    }
    else {
        Add-Content -LiteralPath $SummaryFile -Value "unavailable"
        Add-Content -LiteralPath $SummaryFile -Value ""

        Write-Host "Companion settings: unavailable"
    }
}

function Format-AverageSnr {
    param([double]$Value)

    return ("{0:+0;-0;0}db" -f [math]::Round($Value, 0))
}

function Get-AverageSnrSummary {
    param(
        [double[]]$Sums,
        [int[]]$Counts
    )

    $Parts = @()
    for ($i = 0; $i -lt $Sums.Count; $i++) {
        if ($Counts[$i] -gt 0) {
            $Parts += (Format-AverageSnr -Value ($Sums[$i] / $Counts[$i]))
        }
    }

    if ($Parts.Count -eq 0) {
        return "Average SNR unavailable"
    }

    return "Average SNR " + ($Parts -join ", ")
}

function Get-RadioSettingsCsvValue {
    return "$CompanionRadioFreq,$CompanionRadioBw,$CompanionRadioSf,$CompanionRadioCr"
}

function Parse-Result {
    param([string]$RawText)

    if ($RawText -match "Timeout waiting trace|Traceback \(most recent call last\)|^Error:|Not Connected") {
        return [pscustomobject]@{
            Status = "FAIL"
            SnrValues = ""
        }
    }

    $traceLine = ($RawText -split "`r?`n" | Where-Object { $_ -match '\[' -and $_ -notmatch 'File "' -and $_ -notmatch '\[org\.bluez' -and $_ -notmatch 'Traceback' } | Select-Object -Last 1)
    if (-not $traceLine) {
        return [pscustomobject]@{
            Status = "FAIL"
            SnrValues = ""
        }
    }

    $matches = [regex]::Matches($traceLine, '-?[0-9]+\.[0-9]+')
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Status = "FAIL"
            SnrValues = ""
        }
    }

    return [pscustomobject]@{
        Status = "OK"
        SnrValues = (($matches | ForEach-Object { $_.Value }) -join ",")
    }
}

if (-not (Get-Command meshcli -ErrorAction SilentlyContinue)) {
    throw "meshcli was not found in PATH."
}

$ResolvedPathFile = [System.IO.Path]::GetFullPath($PathFile)
if (-not (Test-Path -LiteralPath $ResolvedPathFile)) {
    throw "Path file not found: $ResolvedPathFile"
}

$ResolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null

$Paths = Get-Content -LiteralPath $ResolvedPathFile |
    ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } |
    Where-Object { $_ }

if ($Paths.Count -eq 0) {
    throw "No valid paths found in $ResolvedPathFile"
}

$TestDate = Get-Date -Format "yyyy-MM-dd"
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$CsvFile = Join-Path $ResolvedOutputDir "meshcore-trace-$Timestamp.csv"
$SummaryFile = Join-Path $ResolvedOutputDir "meshcore-trace-$Timestamp-summary.txt"

@(
    "MeshCore Trace Summary"
    "Date: $TestDate"
    "Path file: $ResolvedPathFile"
    "Runs per path: $Runs"
    "Delay between runs: ${DelaySeconds}s"
    "CSV output: $CsvFile"
    ""
) | Set-Content -LiteralPath $SummaryFile

'date,time,radio_settings,label,path,run,status,snr_values' | Set-Content -LiteralPath $CsvFile
Write-CompanionSettingsSnapshot

for ($index = 0; $index -lt $Paths.Count; $index++) {
    $Label = "PATH$($index + 1)"
    $PathValue = $Paths[$index]
    $Success = 0
    $CompletedAt = ""
    $SnrSums = @()
    $SnrCounts = @()

    Write-Host ""
    Write-Host "=== $Label | $PathValue ==="

    for ($run = 1; $run -le $Runs; $run++) {
        $Now = Get-Date -Format "HH:mm:ss"
        $RawOutput = Get-CleanOutput -RawText (Invoke-MeshCli -Arguments @("trace", $PathValue))
        $Parsed = Parse-Result -RawText $RawOutput
        $RadioSettings = Get-RadioSettingsCsvValue

        if ($Parsed.Status -eq "OK") {
            $Success++
            $SnrParts = $Parsed.SnrValues -split ','
            for ($snrIndex = 0; $snrIndex -lt $SnrParts.Count; $snrIndex++) {
                if ($SnrSums.Count -le $snrIndex) {
                    $SnrSums += 0
                    $SnrCounts += 0
                }
                $SnrSums[$snrIndex] += [double]$SnrParts[$snrIndex]
                $SnrCounts[$snrIndex] += 1
            }

            Add-Content -LiteralPath $CsvFile -Value ('{0},{1},"{2}",{3},"{4}",{5},{6},"{7}"' -f $TestDate, $Now, $RadioSettings, $Label, $PathValue, $run, $Parsed.Status, $Parsed.SnrValues)
            Write-Host "[$Now] $Label run $run/$Runs | OK   | SNRs: $($Parsed.SnrValues) | success $Success/$run"
        }
        else {
            Add-Content -LiteralPath $CsvFile -Value ('{0},{1},"{2}",{3},"{4}",{5},FAIL,""' -f $TestDate, $Now, $RadioSettings, $Label, $PathValue, $run)
            Write-Host "[$Now] $Label run $run/$Runs | FAIL | timeout/no trace | success $Success/$run"
        }

        if ($run -lt $Runs) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $SuccessRate = [math]::Round(($Success / $Runs) * 100, 1)
    $AverageSnrSummary = Get-AverageSnrSummary -Sums $SnrSums -Counts $SnrCounts
    $CompletedAt = Get-Date -Format "HH:mm:ss"
    Add-Content -LiteralPath $SummaryFile -Value "$CompletedAt | $Label | $PathValue | $Success/$Runs success ($SuccessRate`%) | $AverageSnrSummary"
    Write-Host "--- $Label complete | $Success/$Runs success ($SuccessRate`%) | $AverageSnrSummary ---"
}

Write-Host ""
Write-Host "CSV results: $CsvFile"
Write-Host "Summary: $SummaryFile"
