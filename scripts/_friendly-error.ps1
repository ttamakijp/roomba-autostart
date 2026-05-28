# ADR-0015: friendly error helper (PowerShell mirror of _friendly-error.sh).
#
# Dot-source from another script:
#   . "$PSScriptRoot\_friendly-error.ps1"
#   Write-FriendlyError -Code 'LEAK_001' `
#     -What '.gitignore に .env が含まれていません' `
#     -Why  'credentials が誤って commit されるリスク' `
#     -Fix  'scripts/apply-to-project.ps1 -Profile leak-only を実行' `
#     -Doc  'docs/error-codes.md#leak_001'
#
# Or stop the script with the same message:
#   Stop-FriendlyError -Code 'APPLY_002' -Rc 1 -What ... -Why ... -Fix ...

if (Get-Variable -Name FriendlyErrorLoaded -Scope Script -ErrorAction SilentlyContinue) {
  return
}
$Script:FriendlyErrorLoaded = $true

# Force UTF-8 on stderr so the Japanese / emoji output renders correctly
# on Windows terminals (default CP932 garbles it). Linux / macOS terminals
# already default to UTF-8, so this is a no-op there.
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {
  # Some hosts (older Windows PowerShell) reject the assignment; ignore.
}

function Write-FriendlyError {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$What,
    [Parameter(Mandatory = $true)][string]$Why,
    [Parameter(Mandatory = $true)][string]$Fix,
    [string]$Doc = ''
  )

  if ($Code -notmatch '^[A-Z]+_[0-9]+$') {
    [Console]::Error.WriteLine("[friendly_error] WARN: code '$Code' does not match <PREFIX>_<NNN>")
  }

  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("❌ エラー [$Code]")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("何が起きたか:")
  [void]$sb.AppendLine("  $What")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("なぜ:")
  [void]$sb.AppendLine("  $Why")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("どう直すか:")
  [void]$sb.AppendLine("  $Fix")
  if ($Doc) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("  詳しく: $Doc")
  }
  [void]$sb.AppendLine("")

  [Console]::Error.Write($sb.ToString())
}

function Stop-FriendlyError {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][int]$Rc,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$What,
    [Parameter(Mandatory = $true)][string]$Why,
    [Parameter(Mandatory = $true)][string]$Fix,
    [string]$Doc = ''
  )
  Write-FriendlyError -Code $Code -What $What -Why $Why -Fix $Fix -Doc $Doc
  exit $Rc
}
