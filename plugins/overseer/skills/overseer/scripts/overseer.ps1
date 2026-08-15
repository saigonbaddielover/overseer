param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Root = if ($env:OVERSEER_WINDOWS_HOME) { $env:OVERSEER_WINDOWS_HOME } else { Join-Path $env:LOCALAPPDATA 'overseer' }
$script:Client = Join-Path $script:ScriptDir 'win-client.ps1'
$script:Launcher = Join-Path $script:ScriptDir 'win-launch.ps1'
$script:BrokerPayload = Join-Path $script:ScriptDir 'win-broker.ps1'
$script:PollMs = if ($env:OVERSEER_POLL_INTERVAL) { [Math]::Max(1, [int]([double]$env:OVERSEER_POLL_INTERVAL * 1000)) } else { 250 }
$script:DefaultTimeout = if ($env:OVERSEER_TIMEOUT) { [int]$env:OVERSEER_TIMEOUT } else { 600 }

function Fail([string]$Message) { throw "overseer: $Message" }

function ConvertTo-BrokerName([string]$Target) {
  if (-not $Target -or $Target -eq '-' -or $Target -eq 'default') { return 'overseer-broker' }
  if ($Target -notmatch '^[0-9A-Za-z_-]+$') { Fail "invalid target '$Target' (letters, digits, '-' and '_' only)" }
  return "overseer-broker-$Target"
}

function ConvertFrom-BrokerName([string]$Broker) {
  if ($Broker -eq 'overseer-broker') { return 'default' }
  return ($Broker -replace '^overseer-broker-', '')
}

function Invoke-WithBrokerLock {
  param([string]$Target, [scriptblock]$Action)
  $safe = (ConvertTo-BrokerName $Target) -replace '[^0-9A-Za-z_-]', '_'
  $mutex = [Threading.Mutex]::new($false, "Local\sgbl-overseer-$safe")
  $held = $false
  try {
    try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { Fail "another overseer command has held the lock on '$Target' for 30s" }
    & $Action
  } finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Invoke-BrokerClient {
  param(
    [Parameter(Mandatory = $true)][string]$Op,
    [string]$Target = 'default',
    [hashtable]$Parameters = @{},
    [switch]$AllowFailure
  )
  if (-not (Test-Path -LiteralPath $script:Client)) { Fail "missing payload: $script:Client" }
  $broker = ConvertTo-BrokerName $Target
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Client, '-Op', $Op, '-Broker', $broker, '-Root', $script:Root)
  foreach ($key in $Parameters.Keys) { $args += "-$key"; $args += [string]$Parameters[$key] }
  $raw = & (Join-Path $PSHOME 'pwsh.exe') @args 2>&1
  $code = $LASTEXITCODE
  $text = (($raw | ForEach-Object { [string]$_ }) -join "`n").TrimEnd()
  if ($code -ne 0 -and -not $AllowFailure) { Fail "broker '$Target' did not answer '$Op' (exit $code): $text" }
  [PSCustomObject]@{ Text = $text; ExitCode = $code }
}

function Get-BrokerStat([string]$Target) {
  $r = Invoke-BrokerClient -Op stat -Target $Target
  if ($r.Text -notmatch '^kind=(\S+) alive=(\S+) size=(-?\d+) mtime=(\d+) transcript=(.*)$') {
    Fail "malformed broker status for '$Target': $($r.Text)"
  }
  [PSCustomObject]@{
    Kind = $Matches[1]
    Alive = $Matches[2] -eq 'True'
    Size = [long]$Matches[3]
    Mtime = [long]$Matches[4]
    Transcript = $Matches[5] -replace '/', '\'
  }
}

function Get-Snapshot([string]$Target) {
  (Invoke-BrokerClient -Op snap -Target $Target).Text -replace [char]0x00A0, ' '
}

function Get-TextBlocks($Content) {
  if ($null -eq $Content) { return '' }
  return (@($Content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n")
}

function Read-TranscriptState {
  param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$Path, [string]$Want = '')
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $wantTrim = $Want.Trim()
  $turnCount = 0
  $busy = $false
  $running = $false
  $lastPrompt = ''
  $fallbackPrompt = ''
  $lastReply = ''
  $replyFor = ''
  $lastError = ''
  $armed = $false
  $answered = $false
  $queue = New-Object System.Collections.Generic.List[string]
  $ended = @{}
  $started = 0; $completed = 0; $aborted = 0
  $lineNo = 0
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
    $lineNo++
    if (-not $line) { continue }
    try { $e = $line | ConvertFrom-Json -Depth 100 } catch { continue }
    if ($Kind -eq 'claude') {
      if ($e.type -eq 'last-prompt' -and $e.lastPrompt) { $fallbackPrompt = [string]$e.lastPrompt }
      if ($e.type -eq 'queue-operation') {
        if ($e.operation -eq 'enqueue') { $queue.Add([string]$e.content) }
        elseif ($e.operation -eq 'popAll') { $queue.Clear() }
        elseif ($queue.Count -gt 0) { $queue.RemoveAt(0) }
      }
      if ($e.type -eq 'user' -and $e.origin.kind -eq 'human' -and $e.message.content -is [string]) {
        $lastPrompt = [string]$e.message.content
        $running = $true
        if (-not $Want -or $lastPrompt.Trim() -eq $wantTrim) { $armed = $true; $answered = $false; $replyFor = '' }
        else { $armed = $false }
      }
      if ($e.type -eq 'assistant') {
        $stop = [string]$e.message.stop_reason
        if ($stop) { $busy = $stop -eq 'tool_use' }
        $text = Get-TextBlocks $e.message.content
        if ($text) { $lastReply = $text }
        if ($stop -and $stop -ne 'tool_use') {
          $id = if ($e.message.id) { [string]$e.message.id } else { "rec-$lineNo" }
          if (-not $ended.ContainsKey($id)) { $ended[$id] = $true; $turnCount++ }
          $running = $false
          if ($armed) { $answered = $true; if (-not $replyFor -and $text) { $replyFor = $text } }
          if ($e.isApiErrorMessage -eq $true) { $lastError = "$($e.apiErrorStatus)`t$text" } else { $lastError = '' }
        }
      }
    } elseif ($Kind -eq 'codex') {
      if ($e.type -eq 'event_msg') {
        $type = [string]$e.payload.type
        if ($type -eq 'task_started') { $started++; $running = $true }
        elseif ($type -eq 'turn_aborted') { $aborted++; $running = $false }
        elseif ($type -eq 'user_message') {
          $lastPrompt = [string]$e.payload.message
          if (-not $Want -or $lastPrompt.Trim() -eq $wantTrim) { $armed = $true; $answered = $false; $replyFor = '' }
          else { $armed = $false }
        } elseif ($type -eq 'task_complete') {
          $completed++; $turnCount++
          $running = $false
          $text = [string]$e.payload.last_agent_message
          if ($text) { $lastReply = $text }
          if ($armed) { $answered = $true; if (-not $replyFor -and $text) { $replyFor = $text } }
        } elseif ($type -eq 'token_count' -and $e.payload.rate_limits.rate_limit_reached_type) {
          $lastError = "429`tcodex stopped on a usage limit ($($e.payload.rate_limits.rate_limit_reached_type))"
        }
      }
      if ($e.type -eq 'response_item' -and $e.payload.type -eq 'message' -and $e.payload.role -eq 'user') {
        foreach ($part in @($e.payload.content)) {
          if ($part.type -eq 'input_text' -and [string]$part.text -notmatch '^\s*[<#{]') { $fallbackPrompt = [string]$part.text }
        }
      }
    }
    }
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
  if (-not $lastPrompt) { $lastPrompt = $fallbackPrompt }
  if ($Kind -eq 'codex') {
    $busy = $started -gt ($completed + $aborted); $running = $busy
    if ($lastReply) { $lastError = '' }
  }
  [PSCustomObject]@{
    Kind = $Kind; TurnCount = $turnCount; Busy = $busy; Running = $running
    LastPrompt = $lastPrompt; LastReply = $lastReply; ReplyFor = $replyFor
    Answered = $answered; LastError = $lastError; Queue = @($queue)
  }
}

function Get-AgentContext([string]$Target, [string]$Want = '', [switch]$AllowNoTranscript) {
  $stat = Get-BrokerStat $Target
  if ($stat.Kind -notin @('claude', 'codex')) { Fail "'$Target' hosts '$($stat.Kind)', not an agent; start it with claude or codex" }
  if (-not $stat.Alive) { Fail "the agent on '$Target' has exited; start it again" }
  if (-not $stat.Transcript) {
    if ($AllowNoTranscript) { return [PSCustomObject]@{ Stat = $stat; State = $null } }
    Fail "no transcript yet for '$Target' (a new session with zero turns has none)"
  }
  if ($stat.Transcript -notmatch '^[A-Za-z]:\\[A-Za-z0-9\\/:._ -]+\.jsonl$') { Fail "broker reported an unsafe transcript path: $($stat.Transcript)" }
  $state = Read-TranscriptState -Kind $stat.Kind -Path $stat.Transcript -Want $Want
  [PSCustomObject]@{ Stat = $stat; State = $state }
}

function Test-Awaiting([string]$Snapshot) {
  $options = @($Snapshot -split "`r?`n" | Where-Object { $_ -match '^\s*([❯›])?\s*[0-9]+[.)]\s+' })
  if ($options.Count -lt 2) { return $false }
  $marked = @($options | Where-Object { $_ -match '^\s*[❯›]' }).Count
  return $marked -ge 1 -and $marked -lt $options.Count
}

function Write-Awaiting([string]$Target, [string]$Snapshot) {
  "awaiting input — the agent is asking:"
  (($Snapshot -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12) -join "`n"
  "`nanswer with: overseer.ps1 keys $Target <key-or-text>"
}

function ConvertTo-Utf8Base64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
function Normalize-Box([string]$Text) { ($Text -replace '[\s\u00a0]', '') }

function Clear-Box([string]$Target) { $null = Invoke-BrokerClient -Op clear -Target $Target }

function Place-Prompt {
  param([string]$Target, [string]$Prompt, [bool]$Confirm, [bool]$Force)
  $ctx = Get-AgentContext -Target $Target -Want $Prompt -AllowNoTranscript
  $baseline = if ($ctx.State) { $ctx.State.TurnCount } else { 0 }
  if (-not $Force -and $ctx.State -and ($ctx.State.Busy -or $ctx.State.Running)) {
    Fail "the agent on '$Target' is mid-turn; wait or interrupt it, or pass --force deliberately"
  }
  $delivered = $Prompt -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
  if ($ctx.Stat.Kind -eq 'claude' -and $delivered -match '^[/!#@]') { $delivered = " $delivered" }
  if ($ctx.Stat.Kind -eq 'codex' -and $delivered.TrimStart().StartsWith('!')) {
    Fail "Codex runs a message starting with '!' as a shell command; reword it or use a pwsh worker with 'sh'"
  }
  Invoke-WithBrokerLock $Target {
    Clear-Box $Target
    $null = Invoke-BrokerClient -Op paste -Target $Target -Parameters @{ B64 = ConvertTo-Utf8Base64 $delivered }
    $verified = $false
    for ($i = 0; $i -lt 12; $i++) {
      $snap = Get-Snapshot $Target
      $last = @($Prompt -split "`r?`n")[-1]
      if ($snap -match 'Pasted text #[0-9]+ \+[0-9]+ lines' -or ($last -and (Normalize-Box $snap).Contains((Normalize-Box $last)))) { $verified = $true; break }
      Start-Sleep -Milliseconds $script:PollMs
    }
    if (-not $verified) { Clear-Box $Target; Fail "could not verify the prompt in '$Target' input box" }
    if ($Confirm) {
      try { $answer = Read-Host "verified in $Target; press Enter to send or type N to abort" }
      catch { Clear-Box $Target; throw }
      if ($answer -and $answer -notmatch '^[Yy]') { Clear-Box $Target; Fail 'aborted; prompt cleared' }
    }
    $null = Invoke-BrokerClient -Op key -Target $Target -Parameters @{ Name = 'Enter' }
  }
  [PSCustomObject]@{ Baseline = $baseline; Kind = $ctx.Stat.Kind; Prompt = $Prompt }
}

function Wait-ForTurn {
  param([string]$Target, [int]$Baseline, [int]$Timeout, [string]$Prompt = '', [switch]$StartedOnly)
  $deadline = (Get-Date).AddSeconds($Timeout)
  $seenRunning = $false
  $stable = 0
  $cycle = 0
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds $script:PollMs
    $cycle++
    $ctx = Get-AgentContext -Target $Target -Want $Prompt -AllowNoTranscript
    if ($ctx.State) {
      if ($ctx.State.Busy -or $ctx.State.Running) { $seenRunning = $true; $stable = 0 }
      if ($StartedOnly -and (($ctx.State.Busy -or $ctx.State.Running) -or $ctx.State.TurnCount -gt $Baseline)) {
        return [PSCustomObject]@{ Outcome = 'started'; Context = $ctx }
      }
      if (-not $StartedOnly -and ($ctx.State.TurnCount -gt $Baseline -or ($Prompt -and $ctx.State.Answered))) {
        return [PSCustomObject]@{ Outcome = 'complete'; Context = $ctx }
      }
      if (-not $StartedOnly -and $seenRunning -and -not ($ctx.State.Busy -or $ctx.State.Running)) {
        $stable++; if ($stable -ge 3) { return [PSCustomObject]@{ Outcome = 'stopped'; Context = $ctx } }
      }
    }
    if (($cycle % 4) -eq 0) {
      $snap = Get-Snapshot $Target
      if (Test-Awaiting $snap) { return [PSCustomObject]@{ Outcome = 'awaiting'; Context = $ctx; Snapshot = $snap } }
    }
  }
  return [PSCustomObject]@{ Outcome = 'timeout'; Context = $ctx }
}

function Get-Message([string]$Value) {
  if ($Value -eq '-') { return [Console]::In.ReadToEnd() }
  return $Value
}

function Invoke-Start([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 start <name> [pwsh|claude|codex] [workdir]' }
  $which = if ($Values.Count -gt 1) { $Values[1] } else { 'pwsh' }
  if ($which -notin @('pwsh', 'claude', 'codex')) { Fail "child must be pwsh, claude, or codex (got '$which')" }
  $workdir = if ($Values.Count -gt 2) { $Values[2] } else { '' }
  $null = ConvertTo-BrokerName $target
  $payloadDir = Join-Path $script:Root 'payloads'
  $brokerDir = Join-Path $script:Root 'brokers'
  New-Item -ItemType Directory -Force -Path $payloadDir, $brokerDir | Out-Null
  foreach ($file in @('win-broker.ps1', 'win-client.ps1', 'win-launch.ps1')) {
    Copy-Item -LiteralPath (Join-Path $script:ScriptDir $file) -Destination (Join-Path $payloadDir ("overseer-" + $file)) -Force
  }
  $cmd = if ($which -eq 'claude' -and $env:OVERSEER_WIN_CLAUDE) { $env:OVERSEER_WIN_CLAUDE } elseif ($which -eq 'codex' -and $env:OVERSEER_WIN_CODEX) { $env:OVERSEER_WIN_CODEX } else { $which }
  if ($cmd -notmatch '^[A-Za-z0-9_.-]+$') { Fail "agent command '$cmd' must be a bare command name" }
  $la = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Launcher, '-Broker', (ConvertTo-BrokerName $target), '-Which', $which,
    '-WorkDirB64', (ConvertTo-Utf8Base64 $workdir), '-CmdB64', (ConvertTo-Utf8Base64 $cmd), '-Root', $script:Root, '-Local')
  $raw = & (Join-Path $PSHOME 'pwsh.exe') @la 2>&1
  $code = $LASTEXITCODE
  $text = (($raw | ForEach-Object { [string]$_ }) -join "`n").TrimEnd()
  if ($code -ne 0 -or $text -notmatch 'OK broker ready') { Fail "broker launch failed: $text" }
  for ($i = 0; $i -lt 16; $i++) {
    try { if ((Get-Snapshot $target).Trim()) { $text; return } } catch {}
    Start-Sleep -Milliseconds $script:PollMs
  }
  Fail "broker started but '$which' did not paint a screen"
}

function Invoke-List {
  $r = Invoke-BrokerClient -Op list -Target default -AllowFailure
  if ($r.ExitCode -ne 0) { Fail $r.Text }
  $r.Text -replace 'name=-', 'name=default'
}

function Invoke-Peek([string[]]$Values) {
  if (-not $Values[0]) { Fail 'usage: overseer.ps1 peek <name>' }
  Get-Snapshot $Values[0]
}

function Invoke-Keys([string[]]$Values) {
  $target = $Values[0]; if (-not $target -or $Values.Count -lt 2) { Fail 'usage: overseer.ps1 keys <name> <key-or-text>...' }
  Invoke-WithBrokerLock $target {
    foreach ($item in $Values[1..($Values.Count - 1)]) {
      if ($item -match '^(Enter|Escape|Tab|Backspace|Space|Delete|Up|Down|Left|Right|Home|End|PageUp|PageDown|C-[A-Za-z])$') {
        (Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = $item }).Text
      } else {
        (Invoke-BrokerClient -Op type -Target $target -Parameters @{ B64 = ConvertTo-Utf8Base64 $item }).Text
      }
    }
  }
}

function Invoke-Shell([string[]]$Values) {
  $target = $Values[0]; $line = $Values[1]
  if (-not $target -or -not $line) { Fail 'usage: overseer.ps1 sh <name> <command> [timeout]' }
  $timeout = if ($Values.Count -gt 2) { [int]$Values[2] } else { $script:DefaultTimeout }
  $stat = Get-BrokerStat $target
  if ($stat.Kind -ne 'shell') { Fail "'$target' hosts '$($stat.Kind)', not pwsh" }
  $token = "OVSH$PID$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
  $t1 = "${token}B"; $t2 = "${token}E"
  $inject = "Write-Host '$t1'; `$global:LASTEXITCODE=`$null; $line; `$o=`$?; `$c=`$LASTEXITCODE; if (`$null -eq `$c) { `$c=if (`$o) {0} else {1} }; Write-Host '${t2}:'`$c`r"
  $r = Invoke-WithBrokerLock $target {
    $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = 'C-c' }
    Start-Sleep -Milliseconds 150
    Invoke-BrokerClient -Op sh -Target $target -Parameters @{ B64 = ConvertTo-Utf8Base64 $inject; T1 = $t1; T2 = $t2; TimeoutSec = $timeout } -AllowFailure
  }
  $r.Text
  if ($r.ExitCode -ne 0) { Fail "shell command failed through broker '$target'" }
}

function Invoke-Read([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 read <name>' }
  $ctx = Get-AgentContext $target
  $reply = if ($ctx.State.Running) { '(NO REPLY YET — this prompt is still running)' } elseif ($ctx.State.LastError) { "(NO REPLY — API error) $($ctx.State.LastError)" } else { $ctx.State.LastReply }
  "# target=$target harness=$($ctx.Stat.Kind)"
  "## last user prompt:`n$($ctx.State.LastPrompt)"
  "`n## last assistant reply:`n$reply"
}

function Parse-SendArgs([string[]]$Values, [bool]$HasTimeout) {
  $target = $Values[0]; if (-not $target) { Fail 'missing target' }
  $yes = $false; $force = $false; $i = 1
  while ($i -lt $Values.Count -and $Values[$i] -match '^--') {
    if ($Values[$i] -eq '--yes') { $yes = $true }
    elseif ($Values[$i] -eq '--force') { $force = $true }
    else { Fail "unknown option $($Values[$i])" }
    $i++
  }
  if ($i -ge $Values.Count) { Fail 'missing prompt' }
  $prompt = Get-Message $Values[$i]; $i++
  $timeout = if ($HasTimeout -and $i -lt $Values.Count) { [int]$Values[$i] } else { $script:DefaultTimeout }
  [PSCustomObject]@{ Target = $target; Yes = $yes; Force = $force; Prompt = $prompt; Timeout = $timeout }
}

function Invoke-Send([string[]]$Values) {
  $p = Parse-SendArgs $Values $false
  $placed = Place-Prompt -Target $p.Target -Prompt $p.Prompt -Confirm (-not $p.Yes) -Force $p.Force
  $result = Wait-ForTurn -Target $p.Target -Baseline $placed.Baseline -Timeout 10 -Prompt $p.Prompt -StartedOnly
  if ($result.Outcome -eq 'awaiting') { Write-Awaiting $p.Target $result.Snapshot; return }
  if ($result.Outcome -ne 'started') { Fail "sent to '$($p.Target)' but could not confirm the turn started within 10s; peek before resending" }
  "sent to $($p.Target) (turn started):`n$($p.Prompt)"
}

function Invoke-Chat([string[]]$Values) {
  $p = Parse-SendArgs $Values $true
  $placed = Place-Prompt -Target $p.Target -Prompt $p.Prompt -Confirm (-not $p.Yes) -Force $p.Force
  [Console]::Error.WriteLine("# sent to $($p.Target) (waiting for the turn...)")
  $result = Wait-ForTurn -Target $p.Target -Baseline $placed.Baseline -Timeout $p.Timeout -Prompt $p.Prompt
  if ($result.Outcome -eq 'awaiting') { Write-Awaiting $p.Target $result.Snapshot; return }
  if ($result.Outcome -eq 'timeout') { Fail "timeout after $($p.Timeout)s; do not resend—use wait, then read" }
  if ($result.Outcome -eq 'stopped') { Fail 'the turn stopped without producing a reply; peek before deciding whether to resend' }
  $state = Read-TranscriptState -Kind $placed.Kind -Path $result.Context.Stat.Transcript -Want $p.Prompt
  if ($state.LastError) { Fail $state.LastError }
  $reply = if ($state.ReplyFor) { $state.ReplyFor } else { $state.LastReply }
  "## reply:`n$reply"
}

function Invoke-Wait([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 wait <name> [timeout]' }
  $timeout = if ($Values.Count -gt 1) { [int]$Values[1] } else { $script:DefaultTimeout }
  $ctx = Get-AgentContext $target
  $snap = Get-Snapshot $target
  if (Test-Awaiting $snap) { Write-Awaiting $target $snap; return }
  if (-not ($ctx.State.Busy -or $ctx.State.Running)) { 'idle'; return }
  $result = Wait-ForTurn -Target $target -Baseline $ctx.State.TurnCount -Timeout $timeout
  if ($result.Outcome -eq 'awaiting') { Write-Awaiting $target $result.Snapshot }
  elseif ($result.Outcome -eq 'timeout') { Fail "timeout after ${timeout}s; turn is still running" }
  else { 'idle' }
}

function Invoke-Interrupt([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 interrupt <name>' }
  $ctx = Get-AgentContext $target
  if (-not ($ctx.State.Busy -or $ctx.State.Running)) { "$target is idle — nothing to interrupt"; return }
  $key = if ($ctx.Stat.Kind -eq 'claude') { 'C-c' } else { 'Escape' }
  Invoke-WithBrokerLock $target { $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = $key } }
  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 500
    $now = Get-AgentContext $target -AllowNoTranscript
    if (-not $now.State -or -not ($now.State.Busy -or $now.State.Running)) { "interrupted $target — the turn ended with no reply"; return }
  }
  Fail "sent interrupt to '$target' but it still appears busy"
}

function Invoke-Quit([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 quit <name>' }
  $stat = Get-BrokerStat $target
  if ($stat.Kind -notin @('claude', 'codex')) { Fail "'$target' is not an agent" }
  Invoke-WithBrokerLock $target {
    $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = 'C-c' }
    if ($stat.Kind -eq 'claude') { Start-Sleep -Milliseconds 300; $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = 'C-c' } }
  }
  "$($stat.Kind) quit requested on $target"
}

function Invoke-Stop([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 stop <name>' }
  Invoke-WithBrokerLock $target { (Invoke-BrokerClient -Op quit -Target $target -AllowFailure).Text }
}

function Invoke-Slash([string[]]$Values) {
  $target = $Values[0]; $slash = $Values[1]
  if (-not $target -or -not $slash) { Fail 'usage: overseer.ps1 slash <name> </command>' }
  if (-not $slash.StartsWith('/')) { $slash = "/$slash" }
  Invoke-WithBrokerLock $target {
    Clear-Box $target
    $null = Invoke-BrokerClient -Op type -Target $target -Parameters @{ B64 = ConvertTo-Utf8Base64 $slash }
    $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = 'Enter' }
  }
  "submitted $slash to $target"
}

function Invoke-Menu([string[]]$Values) {
  $target = $Values[0]; $name = $Values[1]; $key = if ($Values.Count -gt 2) { $Values[2] } else { 'Down' }
  if (-not $target -or -not $name) { Fail 'usage: overseer.ps1 menu <name> <item> [nav-key]' }
  $escaped = [regex]::Escape($name)
  Invoke-WithBrokerLock $target {
    for ($i = 0; $i -lt 80; $i++) {
      $snap = Get-Snapshot $target
      if ($snap -match "[>❯▶►●➤›]\s*$escaped") { "active: $name"; return }
      $null = Invoke-BrokerClient -Op key -Target $target -Parameters @{ Name = $key }
      Start-Sleep -Milliseconds $script:PollMs
    }
    Fail "could not make '$name' active on '$target'"
  }
}

function Invoke-Doctor([string[]]$Values) {
  "[ok] OS: Windows $([Environment]::OSVersion.Version)"
  "[ok] PowerShell: $($PSVersionTable.PSVersion)"
  foreach ($path in @($script:Client, $script:Launcher, $script:BrokerPayload)) {
    if (Test-Path -LiteralPath $path) { "[ok] payload: $([IO.Path]::GetFileName($path))" } else { Fail "missing payload: $path" }
  }
  foreach ($agent in @('claude', 'codex')) {
    $cmd = Get-Command $agent -ErrorAction SilentlyContinue
    if ($cmd) { "[ok] ${agent}: $($cmd.Source)" } else { "[warn] ${agent}: not on PATH" }
  }
  "[ok] broker root: $script:Root"
  if ($Values -contains '--live') {
    $name = "doctor-$PID"
    try {
      Invoke-Start @($name, 'pwsh', $PWD.Path)
      Invoke-Shell @($name, "Write-Output overseer-windows-live", '20')
      '[ok] live broker round-trip'
    } finally {
      try { Invoke-Stop @($name) | Out-Null } catch {}
    }
  }
}

function Write-Help {
  @'
usage: overseer.ps1 <command> [args]

Native Windows controller (no Linux, WSL, tmux, SSH, or Administrator required):
  start <name> [pwsh|claude|codex] [workdir]  create a visible local worker console
  list                                           list local overseer workers
  peek <name>                                    read the worker screen
  keys <name> <key-or-text>...                   send keys or literal text
  sh <name> <command> [timeout]                  run one PowerShell command
  read <name>                                    read the last agent exchange
  send <name> [--yes] [--force] <prompt|->       send and confirm the turn started
  chat <name> [--yes] [--force] <prompt|-> [s]  send, wait, print the reply
  wait <name> [timeout]                          wait for the current turn
  interrupt <name>                               stop the current turn
  slash <name> </command>                        run an agent slash command
  menu <name> <item> [nav-key]                   navigate a menu by screen verification
  quit <name>                                    exit the agent TUI
  stop <name>                                    destroy the broker and its child
  doctor [--live]                                check the native Windows path

Only sessions created by `start` are drivable. Existing arbitrary console windows cannot be attached.
'@
}

function Invoke-Main {
  switch ($Command) {
    '' { Write-Help }
    '-h' { Write-Help }
    '--help' { Write-Help }
    'help' { Write-Help }
    'start' { Invoke-Start $Rest }
    'list' { Invoke-List }
    'peek' { Invoke-Peek $Rest }
    'keys' { Invoke-Keys $Rest }
    'sh' { Invoke-Shell $Rest }
    'read' { Invoke-Read $Rest }
    'send' { Invoke-Send $Rest }
    'chat' { Invoke-Chat $Rest }
    'wait' { Invoke-Wait $Rest }
    'interrupt' { Invoke-Interrupt $Rest }
    'quit' { Invoke-Quit $Rest }
    'stop' { Invoke-Stop $Rest }
    'slash' { Invoke-Slash $Rest }
    'menu' { Invoke-Menu $Rest }
    'doctor' { Invoke-Doctor $Rest }
    default { Fail "unknown command '$Command'" }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  try { Invoke-Main } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}
