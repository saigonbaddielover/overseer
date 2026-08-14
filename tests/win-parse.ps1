$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bad = 0
$seen = 0
foreach ($file in Get-ChildItem (Join-Path $root 'plugins/overseer/skills/overseer/scripts/win-*.ps1')) {
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
if ($seen -eq 0) { Write-Host 'FAIL: no win-*.ps1 payloads found'; exit 1 }
if ($bad -eq 0) { Write-Host "PASS: $seen windows payloads parse"; exit 0 }
Write-Host 'FAIL: a windows payload does not parse'; exit 1
