$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bad = 0
$seen = 0
$files = @(Get-ChildItem (Join-Path $root 'plugins/overseer/skills/overseer/scripts/win-*.ps1'))
$files += Get-Item (Join-Path $root 'plugins/overseer/skills/overseer/scripts/overseer.ps1')
foreach ($file in $files) {
  $seen++
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
  if ($errors) {
    $bad = 1
    $detail = ($errors | ForEach-Object { $_.Message }) -join ' | '
    Write-Host "  FAIL $($file.Name): $detail"
    if ($env:GITHUB_ACTIONS) { Write-Host "::error file=$($file.Name)::$detail" }
  } else {
    Write-Host "  ok   $($file.Name) parses"
  }
}
if ($seen -eq 0) { Write-Host 'FAIL: no Windows PowerShell scripts found'; exit 1 }
if ($bad -eq 0) { Write-Host "PASS: $seen windows payloads parse"; exit 0 }
Write-Host 'FAIL: a windows payload does not parse'; exit 1
