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
$script:QuotaWarn = 90
$script:QuotaTtl = 300
$script:TranscriptCache = @{}
$script:CommandExitCode = 0
$script:LastSshExitCode = 0

function Fail([string]$Message) { throw "overseer: $Message" }

if ($env:OVERSEER_QUOTA_WARN) {
  $parsedQuotaWarn = 0
  if (-not [int]::TryParse($env:OVERSEER_QUOTA_WARN, [ref]$parsedQuotaWarn)) {
    Fail "OVERSEER_QUOTA_WARN must be a percentage between 1 and 100, got: '$($env:OVERSEER_QUOTA_WARN)'"
  }
  $script:QuotaWarn = $parsedQuotaWarn
}
if ($script:QuotaWarn -lt 1 -or $script:QuotaWarn -gt 100) {
  Fail "OVERSEER_QUOTA_WARN must be a percentage between 1 and 100, got: '$($env:OVERSEER_QUOTA_WARN)'"
}
if ($env:OVERSEER_QUOTA_TTL) {
  $parsedQuotaTtl = 0
  if (-not [int]::TryParse($env:OVERSEER_QUOTA_TTL, [ref]$parsedQuotaTtl)) {
    Fail "OVERSEER_QUOTA_TTL must be a whole number of seconds >= 1, got: '$($env:OVERSEER_QUOTA_TTL)'"
  }
  $script:QuotaTtl = $parsedQuotaTtl
}
if ($script:QuotaTtl -lt 1) {
  Fail "OVERSEER_QUOTA_TTL must be a whole number of seconds >= 1, got: '$($env:OVERSEER_QUOTA_TTL)'"
}

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

function Get-CachedTranscriptState {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][long]$Size,
    [Parameter(Mandatory = $true)][long]$Mtime,
    [string]$Want = ''
  )
  if ($null -eq $script:TranscriptCache) { $script:TranscriptCache = @{} }
  $key = "$Kind`n$Path`n$Want"
  $signature = "${Mtime}:${Size}"
  $cached = $script:TranscriptCache[$key]
  if ($cached -and $cached.Signature -eq $signature) { return $cached.State }
  $state = Read-TranscriptState -Kind $Kind -Path $Path -Want $Want
  $script:TranscriptCache[$key] = [PSCustomObject]@{ Signature = $signature; State = $state }
  return $state
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
  $state = Get-CachedTranscriptState -Kind $stat.Kind -Path $stat.Transcript -Size $stat.Size -Mtime $stat.Mtime -Want $Want
  [PSCustomObject]@{ Stat = $stat; State = $state }
}

function Test-Awaiting([string]$Snapshot) {
  $lines = @($Snapshot -split "`r?`n")
  $options = [Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].TrimStart() -match '^(?<mark>[❯›>])?\s*(?<number>[0-9]+)[.)]\s+') {
      $options.Add([PSCustomObject]@{
        Line = $i
        Number = [int]$Matches.number
        Marked = [bool]$Matches.mark
      })
    }
  }
  for ($i = 0; $i -lt $options.Count; $i++) {
    $j = $i
    $count = 0
    $marked = 0
    while ($j -lt $options.Count) {
      if ($j -gt $i) {
        if ($options[$j].Number -ne ($options[$j - 1].Number + 1)) { break }
        $gap = $options[$j].Line - $options[$j - 1].Line - 1
        if ($gap -gt 3) { break }
        $descriptionOnly = $true
        for ($lineIndex = $options[$j - 1].Line + 1; $lineIndex -lt $options[$j].Line; $lineIndex++) {
          if ($lines[$lineIndex].Trim() -and $lines[$lineIndex] -notmatch '^\s{3,}\S') { $descriptionOnly = $false; break }
        }
        if (-not $descriptionOnly) { break }
      }
      $count++
      if ($options[$j].Marked) { $marked++ }
      $j++
    }
    if ($count -ge 2 -and $marked -ge 1 -and $marked -lt $count) { return $true }
  }
  return $false
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

function ConvertTo-QuotaEpoch($Value) {
  if ($null -eq $Value -or [string]$Value -eq '' -or [string]$Value -eq '0') { return [long]0 }
  $epoch = [long]0
  if ([long]::TryParse([string]$Value, [ref]$epoch)) { return $epoch }
  $stamp = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$stamp)) { return $stamp.ToUnixTimeSeconds() }
  return [long]0
}

function Get-QuotaDuration([long]$Epoch) {
  $seconds = $Epoch - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($seconds -le 0) { return 'now' }
  $days = [Math]::Floor($seconds / 86400)
  $hours = [Math]::Floor(($seconds % 86400) / 3600)
  $minutes = [Math]::Floor(($seconds % 3600) / 60)
  if ($days -gt 0) { return "${days}d${hours}h" }
  if ($hours -gt 0) { return "${hours}h${minutes}m" }
  return "${minutes}m"
}

function ConvertTo-ClaudeQuotaRows($Payload) {
  if ($null -eq $Payload -or [string]$Payload -eq '') { return @() }
  $data = if ($Payload -is [string]) { $Payload | ConvertFrom-Json -Depth 100 } else { $Payload }
  $rows = foreach ($limit in @($data.limits)) {
    $label = if ($limit.kind) { [string]$limit.kind } else { 'quota' }
    if ($limit.scope.model.display_name) { $label += ":$($limit.scope.model.display_name)" }
    [PSCustomObject]@{
      Window = $label
      UsedPercent = [double]$(if ($null -ne $limit.percent) { $limit.percent } else { 0 })
      ResetsAt = ConvertTo-QuotaEpoch $limit.resets_at
      Severity = if ($limit.severity) { [string]$limit.severity } else { 'normal' }
    }
  }
  return @($rows)
}

function Get-CodexWindowLabel($Minutes) {
  if ($null -eq $Minutes) { return 'quota' }
  $value = [int]$Minutes
  if (($value % 1440) -eq 0) { return "$([int]($value / 1440))d" }
  if (($value % 60) -eq 0) { return "$([int]($value / 60))h" }
  return "${value}m"
}

function ConvertTo-CodexQuotaRows($RateLimits) {
  if ($null -eq $RateLimits) { return @() }
  $rows = foreach ($window in @($RateLimits.primary, $RateLimits.secondary)) {
    if ($null -eq $window) { continue }
    [PSCustomObject]@{
      Window = Get-CodexWindowLabel $window.window_minutes
      UsedPercent = [double]$(if ($null -ne $window.used_percent) { $window.used_percent } else { 0 })
      ResetsAt = ConvertTo-QuotaEpoch $window.resets_at
      Severity = 'normal'
    }
  }
  return @($rows)
}

function Get-QuotaBreach($Rows) {
  foreach ($row in @($Rows)) {
    if ($row.Severity -ne 'normal' -or [Math]::Floor([double]$row.UsedPercent) -ge $script:QuotaWarn) { return $row }
  }
  return $null
}

function Write-NativeQuotaRows($Rows) {
  foreach ($row in @($Rows)) {
    $percent = [Math]::Floor([double]$row.UsedPercent)
    $when = if ([long]$row.ResetsAt -gt 0) { "resets in $(Get-QuotaDuration ([long]$row.ResetsAt))" } else { '' }
    if ($row.Severity -ne 'normal' -or $percent -ge $script:QuotaWarn) {
      '  quota {0,-20} {1,5}%  {2,-16} <-- {3}' -f $row.Window, $percent, $when, ([string]$row.Severity).ToUpperInvariant()
    } else {
      '  quota {0,-20} {1,5}%  {2}' -f $row.Window, $percent, $when
    }
  }
}

function Get-ClaudeCredentialsPath {
  $claudeHome = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }
  Join-Path $claudeHome '.credentials.json'
}

function Get-ClaudeQuotaUnavailableReason([int]$Code) {
  $path = Get-ClaudeCredentialsPath
  if ($Code -eq 2) { return "no OAuth credentials in $path — normal on a third-party backend (Bedrock/Vertex/API key/proxy), which has no subscription window" }
  if ($Code -eq 3) { return "the OAuth token in $path has expired — overseer cannot refresh it; run any claude session once to renew it" }
  return 'could not reach https://api.anthropic.com/api/oauth/usage (network, or the endpoint changed)'
}

function Get-ClaudeOAuthCredential {
  $path = Get-ClaudeCredentialsPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [PSCustomObject]@{ Code = 2; Token = '' } }
  try { $credential = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 100 }
  catch { return [PSCustomObject]@{ Code = 2; Token = '' } }
  $token = [string]$credential.claudeAiOauth.accessToken
  if (-not $token) { return [PSCustomObject]@{ Code = 2; Token = '' } }
  $expires = [long]$credential.claudeAiOauth.expiresAt
  if ($expires -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return [PSCustomObject]@{ Code = 3; Token = '' } }
  [PSCustomObject]@{ Code = 0; Token = $token }
}

function Invoke-ClaudeQuotaApi([string]$AccessToken) {
  $headers = @{
    Authorization = "Bearer $AccessToken"
    'anthropic-beta' = 'oauth-2025-04-20'
    Accept = 'application/json'
  }
  Invoke-RestMethod -Method Get -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -TimeoutSec 15
}

function Get-ClaudeQuotaLive {
  $credential = Get-ClaudeOAuthCredential
  if ($credential.Code -ne 0) { return [PSCustomObject]@{ Available = $false; Code = $credential.Code; Payload = $null } }
  try {
    $payload = Invoke-ClaudeQuotaApi $credential.Token
    [PSCustomObject]@{ Available = $true; Code = 0; Payload = $payload }
  } catch {
    [PSCustomObject]@{ Available = $false; Code = 4; Payload = $null }
  }
}

function Get-ClaudeQuotaCachePath { Join-Path (Join-Path $script:Root 'cache') 'quota-claude.json' }

function Set-ClaudeQuotaCache($Payload) {
  $path = Get-ClaudeQuotaCachePath
  $dir = Split-Path -Parent $path
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $temp = "$path.$PID"
  try {
    $Payload | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $path -Force
  } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Get-ClaudeQuotaCached {
  $path = Get-ClaudeQuotaCachePath
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    if ($age.TotalSeconds -lt $script:QuotaTtl) {
      try { return [PSCustomObject]@{ Available = $true; Code = 0; Payload = (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 100) } } catch {}
    }
  }
  $result = Get-ClaudeQuotaLive
  if ($result.Available) { try { Set-ClaudeQuotaCache $result.Payload } catch {} }
  return $result
}

function Get-TranscriptUsage([string]$Kind, [string]$Path) {
  $context = if ($Kind -eq 'codex') { '0/0' } else { '0' }
  $rateLimits = $null
  $plan = '?'
  $limit = '?'
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [PSCustomObject]@{ Context = $context; Rows = @(); Plan = $plan; Limit = $limit }
  }
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if (-not $line) { continue }
      try { $event = $line | ConvertFrom-Json -Depth 100 } catch { continue }
      if ($Kind -eq 'claude' -and $event.type -eq 'assistant' -and $event.message.usage) {
        $usage = $event.message.usage
        $context = [long]$usage.input_tokens + [long]$usage.cache_read_input_tokens + [long]$usage.cache_creation_input_tokens
      }
      if ($Kind -eq 'codex' -and $event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count' -and $event.payload.info) {
        $info = $event.payload.info
        $context = "$([long]$info.last_token_usage.total_tokens)/$([long]$info.model_context_window)"
        if ($event.payload.rate_limits) {
          $rateLimits = $event.payload.rate_limits
          if ($rateLimits.plan_type) { $plan = [string]$rateLimits.plan_type }
          if ($rateLimits.limit_id) { $limit = [string]$rateLimits.limit_id }
        }
      }
    }
  } finally { $reader.Dispose(); $stream.Dispose() }
  [PSCustomObject]@{ Context = [string]$context; Rows = @(ConvertTo-CodexQuotaRows $rateLimits); Plan = $plan; Limit = $limit }
}

function Write-ClaudeUsage([string]$Target, [string]$Transcript, [bool]$Json) {
  $result = Get-ClaudeQuotaLive
  $usage = if ($Transcript) { Get-TranscriptUsage claude $Transcript } else { $null }
  if (-not $result.Available) {
    $why = Get-ClaudeQuotaUnavailableReason $result.Code
    if ($Json) { [ordered]@{ harness = 'claude'; pane = $Target; quota = $null; unavailable = $why } | ConvertTo-Json -Depth 10 -Compress }
    else {
      "# claude$(if ($Target) { " $Target" })  account quota"
      "  quota   n/a            $why"
      if ($usage) { '  context {0,16} tokens in this session (auto-compacts; informational, never a fault)' -f $usage.Context }
    }
    return
  }
  try { Set-ClaudeQuotaCache $result.Payload } catch {}
  $rows = @(ConvertTo-ClaudeQuotaRows $result.Payload)
  if ($Json) {
    $quota = @($rows | ForEach-Object { [ordered]@{ window = $_.Window; used_percent = $_.UsedPercent; resets_at = $_.ResetsAt; severity = $_.Severity } })
    [ordered]@{ harness = 'claude'; pane = $Target; quota = $quota } | ConvertTo-Json -Depth 10 -Compress
    return
  }
  "# claude$(if ($Target) { " $Target" })  account quota (live)"
  Write-NativeQuotaRows $rows
  if ($usage) { '  context {0,16} tokens in this session (auto-compacts; informational, never a fault)' -f $usage.Context }
}

function Write-CodexUsage([string]$Target, [string]$Transcript, [bool]$Json) {
  $usage = Get-TranscriptUsage codex $Transcript
  if ($Json) {
    $quota = @($usage.Rows | ForEach-Object { [ordered]@{ window = $_.Window; used_percent = $_.UsedPercent; resets_at = $_.ResetsAt; severity = $_.Severity } })
    [ordered]@{ harness = 'codex'; pane = $Target; quota = $quota; context = $usage.Context } | ConvertTo-Json -Depth 10 -Compress
    return
  }
  "# codex$(if ($Target) { " $Target" })  plan=$($usage.Plan) limit=$($usage.Limit)"
  if ($usage.Rows.Count) { Write-NativeQuotaRows $usage.Rows }
  else { '  quota   n/a            no subscription window in the rollout — normal on a third-party backend' }
  '  context {0,16} tokens (auto-compacts; informational, never a fault)' -f $usage.Context
}

function Get-QuotaWarningText($Context) {
  if ($null -eq $Context -or $null -eq $Context.Stat) { return '' }
  $rows = if ($Context.Stat.Kind -eq 'claude') {
    $result = Get-ClaudeQuotaCached
    if (-not $result.Available) { return '' }
    @(ConvertTo-ClaudeQuotaRows $result.Payload)
  } elseif ($Context.Stat.Kind -eq 'codex') {
    if (-not $Context.Stat.Transcript) { return '' }
    @(Get-TranscriptUsage codex $Context.Stat.Transcript).Rows
  } else { return '' }
  $breach = Get-QuotaBreach $rows
  if ($null -eq $breach) { return '' }
  "overseer: WARNING $($Context.Stat.Kind) quota $($breach.Window) at $([Math]::Floor([double]$breach.UsedPercent))% — see: overseer.ps1 usage"
}

function Write-QuotaWarningForContext($Context) {
  try {
    $warning = Get-QuotaWarningText $Context
    if ($warning) { [Console]::Error.WriteLine($warning) }
  } catch {}
}

function Invoke-Usage([string[]]$Values) {
  $json = $false
  $target = ''
  foreach ($value in $Values) {
    if ($value -eq '--json') { $json = $true }
    elseif ($value.StartsWith('-')) { Fail 'usage: overseer.ps1 usage [--json] [name]' }
    elseif ($target) { Fail 'usage: overseer.ps1 usage [--json] [name]' }
    else { $target = $value }
  }
  if (-not $target) { Write-ClaudeUsage '' '' $json; return }
  $ctx = Get-AgentContext -Target $target -AllowNoTranscript
  if ($ctx.Stat.Kind -eq 'claude') { Write-ClaudeUsage $target $ctx.Stat.Transcript $json; return }
  if (-not $ctx.Stat.Transcript) { Fail "no rollout for $target yet (a 0-turn codex has none)" }
  Write-CodexUsage $target $ctx.Stat.Transcript $json
}

function ConvertTo-PosixSingleQuoted {
  param([AllowEmptyString()][string]$Value)
  $quote = [string][char]39
  return $quote + $Value.Replace($quote, ($quote + '\' + $quote + $quote)) + $quote
}

function ConvertFrom-SshOptionString([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  $parts = [Collections.Generic.List[string]]::new()
  $word = [Text.StringBuilder]::new()
  $quote = [char]0
  $started = $false
  for ($i = 0; $i -lt $Value.Length; $i++) {
    $ch = $Value[$i]
    if ($quote -eq [char]0 -and [char]::IsWhiteSpace($ch)) {
      if ($started) { $parts.Add($word.ToString()); $null = $word.Clear(); $started = $false }
      continue
    }
    if ($ch -eq "'" -or $ch -eq '"') {
      if ($quote -eq [char]0) { $quote = $ch; $started = $true; continue }
      if ($quote -eq $ch) {
        if (($i + 1) -lt $Value.Length -and $Value[$i + 1] -eq $ch) { $null = $word.Append($ch); $i++; continue }
        $quote = [char]0; continue
      }
    }
    if ($ch -eq '`' -and $quote -ne "'" -and ($i + 1) -lt $Value.Length) {
      $i++; $null = $word.Append($Value[$i]); $started = $true; continue
    }
    $null = $word.Append($ch); $started = $true
  }
  if ($quote -ne [char]0) { Fail "could not parse SSH options '$Value': unclosed $quote quote" }
  if ($started) { $parts.Add($word.ToString()) }
  return @($parts)
}

function Resolve-SshInvocation {
  $spec = if ($env:OVERSEER_SSH) { $env:OVERSEER_SSH } else { 'ssh' }
  $parts = if (Test-Path -LiteralPath $spec -PathType Leaf) { @($spec) } else { @(ConvertFrom-SshOptionString $spec) }
  $parts = @($parts)
  if ($parts.Count -eq 0) { Fail 'ssh is required for on/deploy but OVERSEER_SSH is empty' }
  $command = Get-Command $parts[0] -CommandType Application -ErrorAction SilentlyContinue
  if (-not $command) {
    Fail "ssh is required for on/deploy but '$($parts[0])' is not on PATH; install the Windows OpenSSH Client optional feature or set OVERSEER_SSH"
  }
  [PSCustomObject]@{ Path = $command.Source; Prefix = @($parts | Select-Object -Skip 1) }
}

function Assert-SshAvailable { $null = Resolve-SshInvocation }

function Invoke-OverseerSsh {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$RemoteCommand,
    [string]$InputPath = '',
    [switch]$Quiet
  )
  $ssh = Resolve-SshInvocation
  $sshArgs = @($ssh.Prefix) + @('-o', 'ConnectTimeout=10') + @(ConvertFrom-SshOptionString $env:OVERSEER_SSH_OPTS) + @($HostName, $RemoteCommand)
  if (-not $InputPath) {
    if ($Quiet) { & $ssh.Path @sshArgs *> $null } else { & $ssh.Path @sshArgs }
    $script:LastSshExitCode = $LASTEXITCODE
    return
  }

  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $ssh.Path
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = [bool]$Quiet
  $start.RedirectStandardError = [bool]$Quiet
  foreach ($arg in $sshArgs) { $null = $start.ArgumentList.Add([string]$arg) }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  try {
    if (-not $process.Start()) { Fail 'could not start ssh' }
    $stdout = if ($Quiet) { $process.StandardOutput.ReadToEndAsync() } else { $null }
    $stderr = if ($Quiet) { $process.StandardError.ReadToEndAsync() } else { $null }
    $archiveStream = [IO.File]::OpenRead($InputPath)
    try { $archiveStream.CopyTo($process.StandardInput.BaseStream) } finally { $archiveStream.Dispose(); $process.StandardInput.Close() }
    $process.WaitForExit()
    if ($Quiet) { $null = $stdout.Result; $null = $stderr.Result }
    $script:LastSshExitCode = $process.ExitCode
  } finally {
    $process.Dispose()
  }
}

function Invoke-Deploy([string[]]$Values) {
  $hostName = $Values[0]
  if (-not $hostName) { Fail "usage: overseer.ps1 deploy <host>" }
  Assert-SshAvailable
  $tar = Get-Command tar -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $tar) { Fail 'tar.exe is required for deploy but is not on PATH (Windows 10+ normally includes bsdtar)' }
  $dest = if ($env:OVERSEER_REMOTE_DIR) { $env:OVERSEER_REMOTE_DIR } else { '.overseer' }
  $archive = Join-Path ([IO.Path]::GetTempPath()) ("overseer-$PID-$([Guid]::NewGuid().ToString('N')).tar")
  try {
    & $tar.Source -C (Split-Path -Parent $script:ScriptDir) -cf $archive scripts
    if ($LASTEXITCODE -ne 0) { Fail "tar.exe failed while packaging $script:ScriptDir (exit $LASTEXITCODE)" }
    $remote = 'mkdir -p "$HOME/' + $dest + '" && tar -C "$HOME/' + $dest + '" -xf - && chmod +x "$HOME/' + $dest + '/scripts/overseer"'
    Invoke-OverseerSsh -HostName $hostName -RemoteCommand $remote -InputPath $archive
    if ($script:LastSshExitCode -ne 0) { $script:CommandExitCode = $script:LastSshExitCode; return }
    "overseer: deployed scripts to ${hostName}:~/$dest/"
  } finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-RemoteDeployed([string]$HostName, [string]$RemoteBin) {
  Invoke-OverseerSsh -HostName $HostName -RemoteCommand "[ -f `"$RemoteBin`" ]" -Quiet
  if ($script:LastSshExitCode -eq 0) { return }
  [Console]::Error.WriteLine("overseer: $HostName has no overseer yet — deploying it once...")
  $script:CommandExitCode = 0
  try { Invoke-Deploy @($HostName) | ForEach-Object { [Console]::Error.WriteLine([string]$_) } }
  catch { Fail "auto-deploy to $HostName failed — deploy it manually (overseer deploy $HostName), or set OVERSEER_NO_AUTODEPLOY=1 to skip this" }
  if ($script:CommandExitCode -ne 0) {
    Fail "auto-deploy to $HostName failed — deploy it manually (overseer deploy $HostName), or set OVERSEER_NO_AUTODEPLOY=1 to skip this"
  }
}

function Invoke-On([string[]]$Values) {
  $hostName = $Values[0]
  if (-not $hostName -or $Values.Count -lt 2) {
    Fail "usage: overseer.ps1 on <host> <command> [args]"
  }
  Assert-SshAvailable
  $remoteBin = if ($env:OVERSEER_REMOTE_BIN) { $env:OVERSEER_REMOTE_BIN } else { '$HOME/.overseer/scripts/overseer' }
  if (-not $env:OVERSEER_REMOTE_BIN -and -not $env:OVERSEER_NO_AUTODEPLOY) {
    Ensure-RemoteDeployed -HostName $hostName -RemoteBin $remoteBin
  }
  $quotedParts = @($Values | Select-Object -Skip 1 | ForEach-Object { ConvertTo-PosixSingleQuoted -Value ([string]$_) })
  $quoted = $quotedParts -join ' '
  $remote = "OVS_VIA_ON=1 $remoteBin $quoted"
  Invoke-OverseerSsh -HostName $hostName -RemoteCommand $remote
  $script:CommandExitCode = $script:LastSshExitCode
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
  Write-QuotaWarningForContext $result.Context
  if ($result.Outcome -eq 'awaiting') { Write-Awaiting $p.Target $result.Snapshot; return }
  if ($result.Outcome -ne 'started') { Fail "sent to '$($p.Target)' but could not confirm the turn started within 10s; peek before resending" }
  "sent to $($p.Target) (turn started):`n$($p.Prompt)"
}

function Invoke-Chat([string[]]$Values) {
  $p = Parse-SendArgs $Values $true
  $placed = Place-Prompt -Target $p.Target -Prompt $p.Prompt -Confirm (-not $p.Yes) -Force $p.Force
  [Console]::Error.WriteLine("# sent to $($p.Target) (waiting for the turn...)")
  $result = Wait-ForTurn -Target $p.Target -Baseline $placed.Baseline -Timeout $p.Timeout -Prompt $p.Prompt
  Write-QuotaWarningForContext $result.Context
  if ($result.Outcome -eq 'awaiting') { Write-Awaiting $p.Target $result.Snapshot; return }
  if ($result.Outcome -eq 'timeout') { Fail "timeout after $($p.Timeout)s; do not resend—use wait, then read" }
  if ($result.Outcome -eq 'stopped') { Fail 'the turn stopped without producing a reply; peek before deciding whether to resend' }
  $state = $result.Context.State
  if ($state.LastError) { Fail $state.LastError }
  $reply = if ($state.ReplyFor) { $state.ReplyFor } else { $state.LastReply }
  "## reply:`n$reply"
}

function Invoke-Wait([string[]]$Values) {
  $target = $Values[0]; if (-not $target) { Fail 'usage: overseer.ps1 wait <name> [timeout]' }
  $timeout = if ($Values.Count -gt 1) { [int]$Values[1] } else { $script:DefaultTimeout }
  $snap = Get-Snapshot $target
  if (Test-Awaiting $snap) { Write-Awaiting $target $snap; return }
  $ctx = Get-AgentContext $target
  if (-not ($ctx.State.Busy -or $ctx.State.Running)) { Write-QuotaWarningForContext $ctx; 'idle'; return }
  $result = Wait-ForTurn -Target $target -Baseline $ctx.State.TurnCount -Timeout $timeout
  Write-QuotaWarningForContext $result.Context
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

Native Windows controller (local workers need no Linux, WSL, tmux, SSH, or Administrator):
  start <name> [pwsh|claude|codex] [workdir]  create a visible local worker console
  list                                           list local overseer workers
  peek <name>                                    read the worker screen
  keys <name> <key-or-text>...                   send keys or literal text
  sh <name> <command> [timeout]                  run one PowerShell command
  read <name>                                    read the last agent exchange
  send <name> [--yes] [--force] <prompt|->       send and confirm the turn started
  chat <name> [--yes] [--force] <prompt|-> [s]  send, wait, print the reply
  wait <name> [timeout]                          wait for the current turn
  usage [--json] [name]                         account quota and optional worker context
  interrupt <name>                               stop the current turn
  slash <name> </command>                        run an agent slash command
  menu <name> <item> [nav-key]                   navigate a menu by screen verification
  quit <name>                                    exit the agent TUI
  stop <name>                                    destroy the broker and its child
  doctor [--live]                                check the native Windows path
  on <host> <command> [args]                     run overseer on a Linux host over SSH
  deploy <host>                                  copy the bundled scripts to a Linux host

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
    'usage' { Invoke-Usage $Rest }
    'interrupt' { Invoke-Interrupt $Rest }
    'quit' { Invoke-Quit $Rest }
    'stop' { Invoke-Stop $Rest }
    'slash' { Invoke-Slash $Rest }
    'menu' { Invoke-Menu $Rest }
    'doctor' { Invoke-Doctor $Rest }
    'on' { Invoke-On $Rest }
    'deploy' { Invoke-Deploy $Rest }
    default { Fail "unknown command '$Command'" }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  try { Invoke-Main } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
  if ($script:CommandExitCode -ne 0) { exit $script:CommandExitCode }
}
