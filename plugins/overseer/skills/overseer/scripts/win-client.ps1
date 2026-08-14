param(
  [Parameter(Mandatory = $true)][string]$Op,
  [string]$Broker = 'overseer-broker',
  [string]$B64 = '',
  [string]$Name = '',
  [string]$T1 = '',
  [string]$T2 = '',
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Get-ConfigPath($broker) {
  if ($broker -notmatch '^overseer-broker(?:-[0-9A-Za-z_-]+)?\z') { throw "invalid broker '$broker'" }
  return (Join-Path (Join-Path $env:ProgramData 'overseer\brokers') "$broker.json")
}
function Get-Config($broker) {
  $path = Get-ConfigPath $broker
  if (-not (Test-Path -LiteralPath $path)) { throw "broker '$broker' not found" }
  try { $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { throw "invalid broker descriptor for '$broker'" }
  if (-not $config.Pipe -or -not $config.Token) { throw "incomplete broker descriptor for '$broker'" }
  return $config
}
function Connect-Broker($config) {
  $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $config.Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None, [System.Security.Principal.TokenImpersonationLevel]::Anonymous)
  try { $client.Connect(5000) } catch { try { $client.Dispose() } catch {}; throw 'connect failed' }
  $reader = New-Object System.IO.StreamReader($client)
  $writer = New-Object System.IO.StreamWriter($client); $writer.AutoFlush = $true
  $writer.WriteLine("AUTH $($config.Token)")
  $reply = $reader.ReadLine()
  if ($reply -ne 'OK auth') { try { $client.Dispose() } catch {}; throw 'broker authentication failed' }
  return [PSCustomObject]@{ Client = $client; Reader = $reader; Writer = $writer }
}
function Close-Broker($connection) {
  try { $connection.Writer.WriteLine('BYE') } catch {}
  try { $connection.Client.Dispose() } catch {}
}
function Request($connection, $line) {
  $connection.Writer.WriteLine($line)
  $reply = $connection.Reader.ReadLine()
  if ($null -eq $reply -or -not $reply.StartsWith('OK')) { throw "broker rejected ${line}: $reply" }
  return $reply
}
function Read-Frame($reader) {
  $head = $reader.ReadLine()
  if ($head -ne '<<<SNAP') { throw "malformed snapshot frame: $head" }
  $lines = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $x = $reader.ReadLine()
    if ($null -eq $x) { throw 'truncated snapshot frame' }
    if ($x -eq '>>>SNAP') { return $lines }
    $lines.Add($x)
  }
}
function Label($broker) {
  if ($broker -eq 'overseer-broker') { return '-' }
  return ($broker -replace '^overseer-broker-', '')
}
function Invoke-List {
  $dir = Join-Path $env:ProgramData 'overseer\brokers'
  if (-not (Test-Path -LiteralPath $dir)) { 'none'; return }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'overseer-broker*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.state\.json\z' } | Sort-Object Name)
  if (-not $files) { 'none'; return }
  foreach ($file in $files) {
    $broker = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $label = Label $broker
    try {
      $config = Get-Config $broker
      $connection = Connect-Broker $config
      try {
        $info = Request $connection 'INFO'
        "name=$label $($info.Substring(3))"
      } finally { Close-Broker $connection }
    } catch { "name=$label state=offline" }
  }
}
function Invoke-Client {
  if ($Op -eq 'list') { Invoke-List; return }
  if ($Op -eq 'quit') {
    $configPath = Get-ConfigPath $Broker
    $statePath = $configPath -replace '\.json\z', '.state.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "broker '$Broker' not found" }
    try {
      $connection = Connect-Broker (Get-Config $Broker)
      try { Request $connection 'QUIT' } finally { Close-Broker $connection }
    } catch {
      "OK quit (broker was already gone: $($_.Exception.Message))"
    }
    Remove-Item -LiteralPath $configPath, $statePath -Force -ErrorAction SilentlyContinue
    return
  }
  $config = Get-Config $Broker
  $connection = Connect-Broker $config
  try {
    switch ($Op) {
      'info' { (Request $connection 'INFO').Substring(3) }
      'stat' { (Request $connection 'STAT').Substring(3) }
      'snap' { $connection.Writer.WriteLine('SNAP'); (Read-Frame $connection.Reader) | ForEach-Object { $_ } }
      'type' { Request $connection "TYPE $B64" }
      'paste' { Request $connection "PASTE $B64" }
      'key' { Request $connection "KEY $Name" }
      'clear' { Request $connection 'CLEAR' }
      'sh' {
        $null = Request $connection "TYPE $B64"
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $found = $false
        $lastGrid = @()
        while ((Get-Date) -lt $deadline) {
          Start-Sleep -Milliseconds 400
          $connection.Writer.WriteLine('SNAPALL')
          $lines = Read-Frame $connection.Reader
          if ($lines.Count -eq 0) { continue }
          $lastGrid = $lines
          $i2 = -1
          for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].Trim().StartsWith($T2 + ':')) { $i2 = $k } }
          if ($i2 -ge 0) {
            $i1 = -1
            for ($k = $i2 - 1; $k -ge 0; $k--) { if ($lines[$k].Trim() -eq $T1) { $i1 = $k; break } }
            if ($i1 -ge 0) {
              $rc = $lines[$i2].Trim().Substring($T2.Length + 1)
              '<<<OUT'
              for ($k = $i1 + 1; $k -lt $i2; $k++) { $lines[$k].TrimEnd() }
              '>>>OUT'
              "EXIT $rc"
              $found = $true
              break
            }
          }
        }
        if (-not $found) {
          'ERR sh timeout'
          $lastGrid | Where-Object { $_.Trim() -ne '' } | ForEach-Object { '| ' + $_ }
          exit 3
        }
      }
      default { throw "unknown op $Op" }
    }
  } finally { Close-Broker $connection }
}

try { Invoke-Client } catch { "ERR $($_.Exception.Message)"; exit 3 }
