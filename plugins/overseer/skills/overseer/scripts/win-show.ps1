$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
if ($AppB64) {
  try { $App = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AppB64)) }
  catch { Write-Output 'ERR invalid app encoding'; exit 2 }
}
if (-not $App) { $App = 'Terminal' }
$task = 'overseer-winshow'

try {
  $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
  if (-not $consoleUser) { Write-Output 'ERR no interactive user at the console (locked or logged off); nothing visible to open into'; exit 2 }

  try {
    $exp = Get-Process explorer -IncludeUserName -ErrorAction Stop | Where-Object { $_.UserName -eq $consoleUser } | Select-Object -First 1
  } catch {
    $exp = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  $sid = if ($exp) { $exp.SessionId } else { $null }
  $inSession = { param($p) $null -eq $sid -or $p.SessionId -eq $sid }

  if ($App -match '[\\/]') {
    if (-not (Test-Path -LiteralPath $App)) { Write-Output "ERR no such executable: $App"; exit 3 }
    $action = New-ScheduledTaskAction -Execute $App
    $desc = $App
    $token = [System.IO.Path]::GetFileNameWithoutExtension($App)
  } elseif ($App -match '!') {
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\explorer.exe" -Argument "shell:AppsFolder\$App"
    $desc = $App
    $token = ''
  } else {
    $a = Get-StartApps | Where-Object { $_.Name -match $App } | Select-Object -First 1
    if (-not $a) { Write-Output "ERR no Start app matching '$App' (try an exact name, an AUMID, or a full exe path)"; exit 3 }
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\explorer.exe" -Argument "shell:AppsFolder\$($a.AppID)"
    $desc = $a.Name
    $token = $App
  }

  $before = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { & $inSession $_ } | Select-Object -ExpandProperty Id)

  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(1))
  $prin = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Limited

  $proc = $null; $anyNew = $null
  try {
    Register-ScheduledTask -TaskName $task -Action $action -Settings $set -Principal $prin -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 300
      $fresh = Get-Process -ErrorAction SilentlyContinue | Where-Object { (& $inSession $_) -and $before -notcontains $_.Id }
      if ($fresh) {
        if (-not $anyNew) { $anyNew = $fresh | Select-Object -First 1 }
        if ($token) {
          $m = $fresh | Where-Object { $_.ProcessName -like "*$token*" } | Select-Object -First 1
          if ($m) { $proc = $m; break }
        } else {
          $proc = $anyNew; break
        }
      }
    }
  } finally {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  }
  if (-not $proc) { $proc = $anyNew }

  if ($proc) {
    Write-Output ("OK new '{0}' pid={1} session={2} user={3}" -f $desc, $proc.Id, $proc.SessionId, $consoleUser)
  } else {
    Write-Output ("OK launched '{0}' user={1} (no new process within 10s; it likely focused an already-open window)" -f $desc, $consoleUser)
  }
} catch {
  Write-Output ("ERR " + $_.Exception.Message)
  exit 5
}
