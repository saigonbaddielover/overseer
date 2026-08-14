param(
  [string]$Broker = 'overseer-broker',
  [string]$Which = 'pwsh',
  [string]$WorkDirB64 = '',
  [string]$CmdB64 = ''
)
$ErrorActionPreference = 'Stop'

function Set-SharedAcl($path, $consoleUser) {
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $null = $acl.AddAccessRule($rule)
  }
  if ($consoleUser) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($consoleUser, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $null = $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $path -AclObject $acl
}
function Set-FileAcl($path, $consoleUser, $consoleRights) {
  $owner = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
  $acl = New-Object System.Security.AccessControl.FileSecurity
  $acl.SetAccessRuleProtection($true, $false)
  try { $acl.SetOwner($owner) } catch {}
  foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
    $null = $acl.AddAccessRule($rule)
  }
  if ($consoleUser -and $consoleRights) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($consoleUser, $consoleRights, 'Allow')
    $null = $acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $path -AclObject $acl
}
function Stop-Tree($root, $all) {
  $tree = New-Object System.Collections.Generic.List[int]
  $q = New-Object System.Collections.Generic.Queue[int]
  $q.Enqueue([int]$root)
  while ($q.Count -gt 0) {
    $p = $q.Dequeue()
    $tree.Add($p)
    foreach ($c in ($all | Where-Object { [int]$_.ParentProcessId -eq $p })) { $q.Enqueue([int]$c.ProcessId) }
  }
  $ordered = @($tree)
  for ($k = $ordered.Count - 1; $k -ge 0; $k--) { Stop-Process -Id $ordered[$k] -Force -ErrorAction SilentlyContinue }
}

if ($Broker -notmatch '^overseer-broker(?:-[0-9A-Za-z_-]+)?\z') { "ERR invalid broker '$Broker'"; exit 2 }
try {
  $workDir = if ($WorkDirB64 -and $WorkDirB64 -ne 'fg==') { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($WorkDirB64)) } else { '' }
} catch { 'ERR invalid workdir encoding'; exit 2 }
try {
  $cmdOverride = if ($CmdB64 -and $CmdB64 -ne 'fg==') { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CmdB64)) } else { '' }
} catch { 'ERR invalid command encoding'; exit 2 }
if ($cmdOverride -and $cmdOverride -notmatch '^[A-Za-z0-9_.-]+$') { "ERR invalid agent command '$cmdOverride' (letters, digits, '.', '_' and '-' only)"; exit 2 }
switch ($Which) {
  'pwsh'   { $child = 'pwsh.exe'; $cargs = '-NoLogo'; $kind = 'shell' }
  'claude' { $exe = if ($cmdOverride) { $cmdOverride } else { 'claude' }; $child = 'pwsh.exe'; $cargs = "-NoLogo -Command $exe"; $kind = 'claude' }
  'codex'  { $exe = if ($cmdOverride) { $cmdOverride } else { 'codex' }; $child = 'pwsh.exe'; $cargs = "-NoLogo -Command $exe"; $kind = 'codex' }
  default  { "ERR unknown child '$Which' (use pwsh|claude|codex)"; exit 2 }
}

$root = Join-Path $env:ProgramData 'overseer'
$payloadDir = Join-Path $root 'payloads'
$brokerDir = Join-Path $root 'brokers'
$cu = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $cu) { 'ERR no interactive console user (screen locked or logged off)'; exit 2 }
New-Item -ItemType Directory -Force -Path $root, $payloadDir, $brokerDir | Out-Null
Set-SharedAcl $root $cu
Set-SharedAcl $payloadDir $cu
Set-SharedAcl $brokerDir $cu
$brk = Join-Path $payloadDir 'overseer-win-broker.ps1'
if (-not (Test-Path -LiteralPath $brk)) { "ERR broker payload not found at $brk"; exit 2 }
foreach ($pf in @('overseer-win-broker.ps1', 'overseer-win-client.ps1', 'overseer-win-launch.ps1')) {
  $pfp = Join-Path $payloadDir $pf
  if (Test-Path -LiteralPath $pfp) { Set-FileAcl $pfp $cu 'ReadAndExecute' }
}
$configPath = Join-Path $brokerDir "$Broker.json"
$statePath = Join-Path $brokerDir "$Broker.state.json"

$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
$configPat = [regex]::Escape($configPath)
$stale = @($all | Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'overseer-win-broker' -and $_.CommandLine -match $configPat })
foreach ($b in $stale) { Stop-Tree $b.ProcessId $all }
Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue

$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$pipe = "overseer-$([Guid]::NewGuid().ToString('N'))"
$config = [ordered]@{
  Broker = $Broker
  Pipe = $pipe
  Token = [Convert]::ToBase64String($bytes)
  ConsoleUser = $cu
  Child = $child
  ChildArgs = $cargs
  Kind = $kind
  WorkDir = $workDir
  StatePath = $statePath
  CreatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}
New-Item -ItemType File -Force -Path $configPath | Out-Null
Set-FileAcl $configPath $cu 'ReadAndExecute'
$config | ConvertTo-Json -Compress | Set-Content -LiteralPath $configPath -Encoding UTF8
New-Item -ItemType File -Force -Path $statePath | Out-Null
Set-FileAcl $statePath $cu 'Modify'
'{}' | Set-Content -LiteralPath $statePath -Encoding UTF8

$argline = "-NoProfile -ExecutionPolicy Bypass -File `"$brk`" -Config `"$configPath`""
$act = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argline
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
$prin = New-ScheduledTaskPrincipal -UserId $cu -LogonType Interactive -RunLevel Limited
$task = $Broker
try {
  Register-ScheduledTask -TaskName $task -Action $act -Settings $set -Principal $prin -Force | Out-Null
  Start-ScheduledTask -TaskName $task
} finally {
  Start-Sleep -Milliseconds 1500
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

$ok = $false
for ($t = 0; $t -lt 40; $t++) {
  Start-Sleep -Milliseconds 500
  try { if ([System.IO.Directory]::GetFileSystemEntries('\\.\pipe\') -match ('\\' + [regex]::Escape($pipe) + '$')) { $ok = $true; break } } catch {}
}
if ($ok) { "OK broker ready broker=$Broker child=$Which kind=$kind" } else { Remove-Item -LiteralPath $configPath, $statePath -Force -ErrorAction SilentlyContinue; 'ERR broker pipe not up after 20s'; exit 3 }
