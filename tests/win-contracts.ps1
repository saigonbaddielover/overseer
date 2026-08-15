$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Join-Path (Split-Path -Parent $here) 'plugins/overseer/skills/overseer/scripts'
$fail = 0
$onWindows = ($null -eq $IsWindows) -or $IsWindows
if (-not $env:ProgramData) { $env:ProgramData = [IO.Path]::GetTempPath() }

function Check($name, $expected, $actual) {
  if ($expected -eq $actual) { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n         expected: [$expected]`n         actual:   [$actual]"; $script:fail++ }
}
function Skip($name, $why) { Write-Host "  skip $name ($why)" }

function Import-Fn($file, $name) {
  $path = Join-Path $scripts $file
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
  if ($errs) { throw "parse errors in ${file}: $($errs -join '; ')" }
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
  if (-not $fn) { throw "function $name not found in $file" }
  $def = $fn.Extent.Text -replace "^function\s+$([regex]::Escape($name))", "function global:$name"
  & ([scriptblock]::Create($def))
}

$brokerSrc = Get-Content -Raw (Join-Path $scripts 'win-broker.ps1')
$clientSrc = Get-Content -Raw (Join-Path $scripts 'win-client.ps1')
$launchSrc = Get-Content -Raw (Join-Path $scripts 'win-launch.ps1')
$nativeSrc = Get-Content -Raw (Join-Path $scripts 'overseer.ps1')

Import-Fn 'win-broker.ps1' 'Test-TranscriptPath'
Check 'txpath: accepts a normal claude path' $true (Test-TranscriptPath 'C:/Users/user/.claude/projects/D--Workspace/a-1.jsonl')
Check 'txpath: accepts a normal codex path'  $true (Test-TranscriptPath 'C:/Users/user/.codex/sessions/2026/07/22/rollout-x.jsonl')
Check 'txpath: accepts a backslash path'     $true (Test-TranscriptPath 'C:\Users\user\.claude\projects\x\y.jsonl')
Check 'txpath: accepts a spaced username'    $true (Test-TranscriptPath 'C:/Users/John Doe/.claude/projects/x/y.jsonl')
Check 'txpath: rejects an ampersand'         $false (Test-TranscriptPath "C:/Users/x/rollout-a & calc.jsonl")
Check 'txpath: rejects a command sub'        $false (Test-TranscriptPath 'C:/Users/x/$(calc).jsonl')
Check 'txpath: rejects a semicolon'          $false (Test-TranscriptPath 'C:/Users/x/a;b.jsonl')
Check 'txpath: rejects a pipe'               $false (Test-TranscriptPath 'C:/Users/x/a|b.jsonl')
Check 'txpath: rejects a non-jsonl suffix'   $false (Test-TranscriptPath 'C:/Users/x/a.txt')
Check 'txpath: rejects a unix path'          $false (Test-TranscriptPath '/etc/passwd')
Check 'txpath: rejects an empty string'      $false (Test-TranscriptPath '')

Import-Fn 'win-client.ps1' 'Get-ConfigPath'
Check 'configpath: accepts the bare broker'     $true  ((Get-ConfigPath 'overseer-broker') -match 'overseer-broker\.json\z')
Check 'configpath: accepts a named broker'      $true  ((Get-ConfigPath 'overseer-broker-two') -match 'overseer-broker-two\.json\z')
Check 'configpath: never resolves a state file' $false ((Get-ConfigPath 'overseer-broker') -match '\.state\.json')
foreach ($bad in @('overseer-broker/../evil', 'overseer-broker;calc', 'other', 'overseer-broker.state', "overseer-broker`nx")) {
  $threw = $false
  try { Get-ConfigPath $bad } catch { $threw = $true }
  Check "configpath: rejects '$bad'" $true $threw
}

Import-Fn 'win-client.ps1' 'Label'
Check 'label: the bare broker is a dash' '-'   (Label 'overseer-broker')
Check 'label: strips the broker prefix'  'two' (Label 'overseer-broker-two')

Import-Fn 'win-client.ps1' 'Read-Frame'
$good = New-Object System.IO.StringReader("<<<SNAP`nline one`nline two`n>>>SNAP`n")
$lines = Read-Frame $good
Check 'frame: returns the body lines'     'line one|line two' ($lines -join '|')
$bad = New-Object System.IO.StringReader("GARBAGE`nbody`n>>>SNAP`n")
$threw = $false; try { Read-Frame $bad } catch { $threw = $true }
Check 'frame: rejects a bad header'       $true $threw
$trunc = New-Object System.IO.StringReader("<<<SNAP`nonly one line`n")
$threw = $false; try { Read-Frame $trunc } catch { $threw = $true }
Check 'frame: rejects a truncated frame'  $true $threw

$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$descriptor = [ordered]@{
  Broker = 'overseer-broker'; Pipe = "overseer-$([Guid]::NewGuid().ToString('N'))"
  Token = [Convert]::ToBase64String($bytes); ConsoleUser = 'HOST\u'; Child = 'pwsh.exe'
  ChildArgs = '-NoLogo'; Kind = 'shell'; WorkDir = ''; StatePath = 'C:\x\overseer-broker.state.json'
  CreatedAt = 1
}
$parsed = ($descriptor | ConvertTo-Json -Compress) | ConvertFrom-Json
Check 'descriptor: round-trips the pipe'          $descriptor.Pipe  $parsed.Pipe
Check 'descriptor: round-trips the token'         $descriptor.Token $parsed.Token
Check 'descriptor: carries a state path'          $true ([bool]$parsed.StatePath)
Check 'descriptor: the secret has no transcript claim' $false ($parsed.PSObject.Properties.Name -contains 'Transcript')

if ($onWindows) {
  Import-Fn 'win-broker.ps1' 'Get-ClaimedTranscripts'
  Import-Fn 'win-broker.ps1' 'Set-ClaimedTranscript'
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ov-" + [Guid]::NewGuid().ToString('N'))
  $bdir = Join-Path $tmp 'overseer\brokers'
  New-Item -ItemType Directory -Force -Path $bdir | Out-Null
  $oldPd = $env:ProgramData; $env:ProgramData = $tmp
  try {
    '{"Transcript":"C:/sibling/rollout-A.jsonl"}' | Set-Content -LiteralPath (Join-Path $bdir 'overseer-broker-sib.state.json')
    $Config = Join-Path $bdir 'overseer-broker.json'
    $StatePath = Join-Path $bdir 'overseer-broker.state.json'
    '{}' | Set-Content -LiteralPath $StatePath
    $claimed = Get-ClaimedTranscripts
    Check 'claim: a broker sees a sibling claim'        $true  ($claimed -contains 'C:/sibling/rollout-A.jsonl')
    Set-ClaimedTranscript 'C:/mine/rollout-B.jsonl'
    $mine = (Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json).Transcript
    Check 'claim: a broker records its own claim to state' 'C:/mine/rollout-B.jsonl' $mine
    $claimed2 = Get-ClaimedTranscripts
    Check 'claim: a broker never lists its own claim'   $false ($claimed2 -contains 'C:/mine/rollout-B.jsonl')
  } finally { $env:ProgramData = $oldPd; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
} else {
  Skip 'claim: codex claim isolation' 'ProgramData path is Windows-only; CI runs it on windows-latest'
}

Check 'src: broker builds an explicit pipe ACL'                 $true  ($brokerSrc -match 'PipeAccessRule')
Check 'src: broker demands a first pipe instance'               $true  ($brokerSrc -match 'PipeOptions\]::FirstPipeInstance')
Check 'src: broker pipe ctor has a PS5 fallback'                $true  (($brokerSrc -match 'NamedPipeServerStreamAcl') -and ($brokerSrc -match 'New-Object -TypeName System\.IO\.Pipes\.NamedPipeServerStream'))
Check 'src: broker compares the auth token length-first, Ordinal' $true (($brokerSrc -match '\$auth\.Length -ne \$want\.Length') -and ($brokerSrc -match '\[string\]::Equals\(\$auth, \$want, \[StringComparison\]::Ordinal\)'))
Check 'src: broker writes its claim to state, not the secret'   $true  (($brokerSrc -match 'Set-Content -LiteralPath \$StatePath') -and -not ($brokerSrc -match 'ConvertTo-Json -Compress \| Set-Content -LiteralPath \$Config '))
Check 'src: broker validates the transcript before emitting'    $true  (($brokerSrc -match 'transcript=\$tx') -and ($brokerSrc -match 'Test-TranscriptPath \$tx'))
Check 'src: broker kills the whole child tree'                  $true  ($brokerSrc -match 'Stop-Descendants \$childPid')
Check 'src: broker exposes scrollback + clear for win sh'       $true  (($brokerSrc -match "verb -eq 'SNAPALL'") -and ($brokerSrc -match "verb -eq 'CLEAR'"))
Check 'src: broker logs terminating errors'                     $true  ($brokerSrc -match 'trap \{ Log "FATAL')

Check 'src: client connects anonymously (no impersonation)'     $true  ($clientSrc -match 'TokenImpersonationLevel\]::Anonymous')
Check 'src: client authenticates before any verb'               $true  ($clientSrc -match 'AUTH \$\(\$config\.Token\)')
Check 'src: client fails nonzero on error'                      $true  ($clientSrc -match 'exit 3')
Check 'src: quit removes both descriptor files'                 $true  ($clientSrc -match 'Remove-Item -LiteralPath \$configPath, \$statePath')

Check 'src: launcher takes workdir + agent command as base64'   $true  (($launchSrc -match '\$WorkDirB64') -and ($launchSrc -match '\$CmdB64'))
Check 'src: launcher never interpolates workdir into a command' $false ($launchSrc -match '-WorkDir "\$')
Check 'src: launcher validates the agent command charset'       $true  ($launchSrc -match "cmdOverride -notmatch '\^\[A-Za-z0-9_\.-\]\+\`$'")
Check 'src: launcher mints a random pipe + capability token'    $true  (($launchSrc -match 'Guid\]::NewGuid') -and ($launchSrc -match 'RandomNumberGenerator'))
Check 'src: launcher secret file is console-user read-only'     $true  ($launchSrc -match "Set-FileAcl \`$configPath \`$cu 'ReadAndExecute'")
Check 'src: launcher gives a separate writable state file'      $true  ($launchSrc -match "Set-FileAcl \`$statePath \`$cu 'Modify'")
Check 'src: launcher drops Authenticated Users from shared dirs' $false ($launchSrc -match 'Authenticated Users')
Check 'src: launcher exits nonzero when the pipe never appears' $true  ($launchSrc -match "'ERR broker pipe not up after 20s'; exit 3")
Check 'src: no payload assigns the read-only $pid automatic'    $false (($brokerSrc + $clientSrc + $launchSrc) -match '(foreach|for)\s*\(\s*\$pid\b')
Check 'src: client accepts a controller-selected broker root'   $true  (($clientSrc -match '\[string\]\$Root') -and ($clientSrc -match 'if \(\$Root\)'))
Check 'src: local launcher bypasses the scheduled-task bridge'  $true  (($launchSrc -match 'if \(\$Local\)') -and ($launchSrc -match 'Start-Process') -and ($launchSrc -match 'WindowStyle Normal'))
Check 'src: native transcript tail shares a live rollout'       $true  ($nativeSrc -match 'FileShare\]::ReadWrite -bor \[IO\.FileShare\]::Delete')
Check 'src: native delivery refuses codex shell-command mode'   $true  ($nativeSrc -match "Codex runs a message starting with '!'")
Check 'src: native shell cancels a stale input line first'      $true  (($nativeSrc -match "Name = 'C-c'") -and ($nativeSrc -match 'Invoke-BrokerClient -Op sh'))

if ($onWindows) {
  $native = Join-Path $scripts 'overseer.ps1'
  . $native
  $fixtures = Join-Path $here 'fixtures'
  $cl = Read-TranscriptState -Kind claude -Path (Join-Path $fixtures 'claude-turn.jsonl') -Want 'second prompt'
  Check 'native parser: claude turn count'       2 $cl.TurnCount
  Check 'native parser: claude last prompt'      'second prompt' $cl.LastPrompt
  Check 'native parser: claude paired reply'     "final reply`nsecond line" $cl.ReplyFor
  Check 'native parser: completed claude idle'   $false $cl.Busy
  $clBusy = Read-TranscriptState -Kind claude -Path (Join-Path $fixtures 'claude-busy.jsonl')
  Check 'native parser: busy claude detected'    $true $clBusy.Busy
  $cx = Read-TranscriptState -Kind codex -Path (Join-Path $fixtures 'codex-turn.jsonl') -Want 'codex prompt here'
  Check 'native parser: codex turn count'        1 $cx.TurnCount
  Check 'native parser: codex last prompt'       'codex prompt here' $cx.LastPrompt
  Check 'native parser: codex paired reply'      'codex reply text' $cx.ReplyFor
  $cxBusy = Read-TranscriptState -Kind codex -Path (Join-Path $fixtures 'codex-busy.jsonl')
  Check 'native parser: busy codex detected'     $true $cxBusy.Busy
} else {
  Skip 'native controller transcript parser' 'native controller runs on Windows; CI covers it on windows-latest'
}

if ($fail -eq 0) { Write-Host 'PASS: windows payload contracts'; exit 0 }
Write-Host "FAIL: $fail contract check(s) failed"; exit 1
