#Requires -Version 5.1
<#
.SYNOPSIS
  Windows PC リソース観測 collector — ADR-0017 Phase 3。

.DESCRIPTION
  Get-Counter で CPU / RAM / Disk I/O を直近 N 秒 (default 60s) サンプリングし、
  self-hosted runner プロセス (`Runner.Listener` / `Runner.Worker`) の使用率を
  分離して JSON で stdout に出す。

  目的: ADR-0016 で同居化した runner と主作業の **干渉度** を可視化。
  runner プロセスの CPU が 80% 超 = 主作業への影響大の警告条件。

  出力 schema:

    {
      "samples": <N>,
      "duration_sec": <S>,
      "cpu_total_pct_avg": 12.3,
      "ram_used_mb_avg": 6500,
      "ram_total_mb": 16384,
      "ram_used_pct_avg": 39.7,
      "disk_read_mb_per_sec_avg": 1.2,
      "disk_write_mb_per_sec_avg": 3.4,
      "runner_processes": [
        { "name": "Runner.Listener", "pid": 1234, "cpu_pct_avg": 2.1 },
        ...
      ],
      "runner_cpu_pct_avg": 2.1,
      "warning": "runner CPU usage HIGH (>80%) — likely impacting main workload"
    }

  -DryRun 指定で perf counter を叩かず、stub JSON を出す (syntax / smoke
  testing 用)。

.PARAMETER DurationSec
  サンプリング時間 (秒)。default 60。

.PARAMETER SampleInterval
  サンプル間隔 (秒)。default 5。

.PARAMETER DryRun
  perf counter 取得を skip、stub を出力。

.EXAMPLE
  pwsh -File scripts/cost-collect-pc-resource.ps1

.EXAMPLE
  pwsh -File scripts/cost-collect-pc-resource.ps1 -DurationSec 30 -SampleInterval 3

.NOTES
  Refs: ADR-0017
#>
[CmdletBinding()]
param(
  [int]$DurationSec = 60,
  [int]$SampleInterval = 5,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Emit-Json {
  param([Parameter(Mandatory = $true)]$Obj)
  $json = ($Obj | ConvertTo-Json -Compress -Depth 6)
  [Console]::Out.WriteLine($json)
}

function Emit-Unavailable {
  param([string]$Reason)
  Write-Warning "[cost-collect-pc-resource] $Reason"
  Emit-Json @{ unavailable = $true; reason = $Reason }
  exit 0
}

if ($DryRun) {
  Write-Warning "[cost-collect-pc-resource] dry-run: emitting stub."
  Emit-Json @{
    unavailable = $true
    reason      = 'dry-run'
  }
  exit 0
}

if ($DurationSec -lt 5) { $DurationSec = 5 }
if ($SampleInterval -lt 1) { $SampleInterval = 1 }
$maxSamples = [Math]::Max(1, [int]($DurationSec / $SampleInterval))

# --- counters -------------------------------------------------------------
$counters = @(
  '\Processor(_Total)\% Processor Time',
  '\Memory\Available MBytes',
  '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
  '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
)

try {
  $samples = Get-Counter -Counter $counters -SampleInterval $SampleInterval -MaxSamples $maxSamples -ErrorAction Stop
} catch {
  Emit-Unavailable "Get-Counter failed: $($_.Exception.Message)"
}

$cpuVals      = @()
$ramAvailVals = @()
$rdVals       = @()
$wrVals       = @()

foreach ($s in $samples) {
  foreach ($c in $s.CounterSamples) {
    switch -wildcard ($c.Path) {
      '*\processor(_total)\% processor time'        { $cpuVals      += [double]$c.CookedValue }
      '*\memory\available mbytes'                   { $ramAvailVals += [double]$c.CookedValue }
      '*\physicaldisk(_total)\disk read bytes/sec'  { $rdVals       += [double]$c.CookedValue }
      '*\physicaldisk(_total)\disk write bytes/sec' { $wrVals       += [double]$c.CookedValue }
    }
  }
}

# avg helper
function _avg($arr) {
  if (-not $arr -or $arr.Count -eq 0) { return 0.0 }
  return [Math]::Round((($arr | Measure-Object -Average).Average), 2)
}

# Total RAM (MB) — pulled once.
$ramTotalMb = 0
try {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $ramTotalMb = [int]([Math]::Round(($cs.TotalPhysicalMemory / 1MB), 0))
} catch {
  $ramTotalMb = 0
}

$ramAvailAvg = _avg $ramAvailVals
$ramUsedAvg  = if ($ramTotalMb -gt 0) { $ramTotalMb - $ramAvailAvg } else { 0 }
$ramUsedPct  = if ($ramTotalMb -gt 0) { [Math]::Round((($ramUsedAvg / $ramTotalMb) * 100), 2) } else { 0 }

$cpuAvg      = _avg $cpuVals
$diskReadMb  = [Math]::Round(((_avg $rdVals) / 1MB), 2)
$diskWriteMb = [Math]::Round(((_avg $wrVals) / 1MB), 2)

# --- runner process isolation --------------------------------------------
# Runner.Listener.exe / Runner.Worker.exe are the official agent processes.
# Get-Process CPU is cumulative seconds since start, so we take 2 snapshots
# `$DurationSec` apart and diff to get CPU seconds during the window, then
# divide by (DurationSec * NumberOfLogicalProcessors) to get % per logical CPU.
$runnerNames = @('Runner.Listener', 'Runner.Worker')

function _snap_runner_cpu {
  $snap = @{}
  foreach ($n in $runnerNames) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
      $snap["$($_.Id):$($_.ProcessName)"] = [double]$_.CPU
    }
  }
  return $snap
}

$cpuLogical = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue |
  Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
if (-not $cpuLogical -or $cpuLogical -lt 1) { $cpuLogical = 1 }

$snapA = _snap_runner_cpu
Start-Sleep -Seconds ([Math]::Min(10, $DurationSec))
$snapB = _snap_runner_cpu

$elapsedSec = [Math]::Min(10, $DurationSec)
$runnerProcs = @()
$runnerTotalPct = 0.0
foreach ($k in $snapB.Keys) {
  if (-not $snapA.ContainsKey($k)) { continue }
  $deltaSec = [double]($snapB[$k] - $snapA[$k])
  if ($deltaSec -lt 0) { $deltaSec = 0 }
  $pct = [Math]::Round((($deltaSec / ($elapsedSec * $cpuLogical)) * 100), 2)
  $parts = $k.Split(':', 2)
  $runnerProcs += [pscustomobject]@{
    name        = $parts[1]
    pid         = [int]$parts[0]
    cpu_pct_avg = $pct
  }
  $runnerTotalPct += $pct
}

$warning = ''
if ($runnerTotalPct -gt 80) {
  $warning = 'runner CPU usage HIGH (>80%) — likely impacting main workload'
} elseif ($cpuAvg -gt 90) {
  $warning = 'overall CPU saturation (>90%) — investigate other heavy processes'
}

Emit-Json @{
  samples                  = $cpuVals.Count
  duration_sec             = $DurationSec
  cpu_total_pct_avg        = $cpuAvg
  ram_used_mb_avg          = $ramUsedAvg
  ram_total_mb             = $ramTotalMb
  ram_used_pct_avg         = $ramUsedPct
  disk_read_mb_per_sec_avg = $diskReadMb
  disk_write_mb_per_sec_avg = $diskWriteMb
  runner_processes         = $runnerProcs
  runner_cpu_pct_avg       = [Math]::Round($runnerTotalPct, 2)
  warning                  = $warning
}
