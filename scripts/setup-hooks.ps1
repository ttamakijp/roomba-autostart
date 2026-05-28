# Activate repo-local git hooks under .githooks/.
# Run once per clone:
#   pwsh scripts/setup-hooks.ps1
$ErrorActionPreference = "Stop"

$root = (git rev-parse --show-toplevel)
Set-Location $root

# Required hooks. Listed explicitly so a missing file early-fails this
# setup script instead of silently producing an unprotected clone.
$requiredHooks = @("pre-commit", "pre-push")
foreach ($h in $requiredHooks) {
  if (-not (Test-Path ".githooks/$h")) {
    Write-Error "required hook .githooks/$h is missing"
    exit 1
  }
}

git config core.hooksPath .githooks

Write-Host "Hooks activated."
Write-Host "  core.hooksPath = $(git config core.hooksPath)"
Write-Host "  Hooks:"
Get-ChildItem .githooks | ForEach-Object { Write-Host "    $($_.Name)" }
