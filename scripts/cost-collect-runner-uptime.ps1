#Requires -Version 5.1
<#
.SYNOPSIS
  self-hosted runner uptime SLI collector — ADR-0017 Phase 3。

.DESCRIPTION
  Task Scheduler の `GitHubRunner-*` Task を全列挙し、各 Task の直近 N 日
  (default 7) の uptime % を計算して JSON で stdout に出す。

  uptime 計算:
    - 「Task Scheduler 上で Ready / Running 状態だった時間」を
      `Get-ScheduledTaskInfo` の LastRunTime / NextRunTime と Application
      イベントログから推定
    - 厳密な run-state ログは Windows 標準で取りにくいので、heuristic として
      Last N 日のうち Task が `Running` で観測された確率を 1 時間サンプル
      ベースで近似 (Get-ScheduledTaskInfo + 過去 N 日の event log の Task
      Started / Stopped イベントの累積時間で補正)

  出力 schema:

    {
      "tasks": [
        {
          "name": "GitHubRunner-tackt",
          "uptime_pct": 99.5,
          "last_run_time": "2026-05-23T08:11:00",
          "state": "Running",
          "warning": ""
        },
        ...
      ],
      "overall_uptime_pct": 99.5,
      "warning": ""
    }

  -DryRun で Task 列挙を skip。

.PARAMETER WindowDays
  uptime 計算の window。default 7。

.PARAMETER DryRun
  Task Scheduler 列挙を skip、stub を出力。

.EXAMPLE
  pwsh -File scripts/cost-collect-runner-uptime.ps1

.NOTES
  Refs: ADR-0017
#>
[CmdletBinding()]
param(
  [int]$WindowDays = 7,
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
  Write-Warning "[cost-collect-runner-uptime] $Reason"
  Emit-Json @{ unavailable = $true; reason = $Reason; tasks = @(); overall_uptime_pct = 0 }
  exit 0
}

if ($DryRun) {
  Write-Warning "[cost-collect-runner-uptime] dry-run: emitting stub."
  Emit-Json @{
    unavailable        = $true
    reason             = 'dry-run'
    tasks              = @()
    overall_uptime_pct = 0
  }
  exit 0
}

if ($WindowDays -lt 1) { $WindowDays = 1 }
if ($WindowDays -gt 90) { $WindowDays = 90 }

try {
  $tasks = Get-ScheduledTask -TaskName 'GitHubRunner-*' -ErrorAction Stop
} catch {
  Emit-Unavailable "Get-ScheduledTask failed (Windows only): $($_.Exception.Message)"
}

if (-not $tasks -or $tasks.Count -eq 0) {
  Emit-Unavailable "no GitHubRunner-* tasks found (ADR-0016 setup not applied on this host)"
}

$now = Get-Date
$windowStart = $now.AddDays(-$WindowDays)
$windowSec = ($now - $windowStart).TotalSeconds

$results = @()
$pctSum = 0.0
$pctCount = 0

foreach ($t in $tasks) {
  $info = $null
  try {
    $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop
  } catch {
    $info = $null
  }

  $taskName = $t.TaskName
  $state    = $t.State.ToString()
  $lastRun  = if ($info -and $info.LastRunTime) { $info.LastRunTime } else { $null }

  # heuristic uptime estimate via event log scan
  $uptimeSec = 0.0
  try {
    $filter = @{
      LogName      = 'Microsoft-Windows-TaskScheduler/Operational'
      ID           = 100, 102  # 100=Task Started, 102=Task Completed
      StartTime    = $windowStart
    }
    $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -and $_.Message.IndexOf($taskName) -ge 0 } |
      Sort-Object TimeCreated
    if ($events) {
      $pendingStart = $null
      foreach ($ev in $events) {
        if ($ev.Id -eq 100) {
          $pendingStart = $ev.TimeCreated
        } elseif ($ev.Id -eq 102 -and $pendingStart) {
          $delta = ($ev.TimeCreated - $pendingStart).TotalSeconds
          if ($delta -gt 0) { $uptimeSec += $delta }
          $pendingStart = $null
        }
      }
      if ($pendingStart) {
        $delta = ($now - $pendingStart).TotalSeconds
        if ($delta -gt 0) { $uptimeSec += $delta }
      }
    }
  } catch {
    # Event log access may be restricted; fall back to simple state heuristic.
    $uptimeSec = 0
  }

  if ($uptimeSec -le 0 -and $state -eq 'Running') {
    # If we couldn't read events but the task IS running right now, assume
    # at least the typical "logon → now" portion of the window.
    $uptimeSec = $windowSec * 0.5
  }

  $uptimePct = if ($windowSec -gt 0) {
    [Math]::Round((($uptimeSec / $windowSec) * 100), 2)
  } else { 0 }
  if ($uptimePct -gt 100) { $uptimePct = 100 }

  $warn = ''
  if ($state -ne 'Running' -and $state -ne 'Ready') {
    $warn = "task state is '$state' — runner is NOT autostarting"
  } elseif ($uptimePct -lt 95 -and $WindowDays -ge 7) {
    $warn = "uptime $uptimePct% below 95% SLI"
  }

  $results += [pscustomobject]@{
    name          = $taskName
    uptime_pct    = $uptimePct
    last_run_time = if ($lastRun) { $lastRun.ToString('s') } else { '' }
    state         = $state
    warning       = $warn
  }
  $pctSum += $uptimePct
  $pctCount += 1
}

$overall = if ($pctCount -gt 0) { [Math]::Round(($pctSum / $pctCount), 2) } else { 0 }
$overallWarn = ''
if ($overall -lt 95) {
  $overallWarn = "overall runner uptime $overall% below 95% SLI"
}

Emit-Json @{
  tasks              = $results
  overall_uptime_pct = $overall
  window_days        = $WindowDays
  warning            = $overallWarn
}
