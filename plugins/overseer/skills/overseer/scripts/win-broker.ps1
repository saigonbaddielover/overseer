param(
  [Parameter(Mandatory = $true)][string]$Config
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Config)) { 'ERR broker config not found'; exit 2 }
try { $cfg = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json } catch { "ERR invalid broker config: $($_.Exception.Message)"; exit 2 }
$Child = [string]$cfg.Child
$ChildArgs = [string]$cfg.ChildArgs
$Pipe = [string]$cfg.Pipe
$Token = [string]$cfg.Token
$Kind = [string]$cfg.Kind
$WorkDir = [string]$cfg.WorkDir
$ConsoleUser = [string]$cfg.ConsoleUser
$StatePath = [string]$cfg.StatePath
if (-not $Child -or -not $Pipe -or -not $Token -or -not $Kind -or -not $ConsoleUser) { 'ERR incomplete broker config'; exit 2 }
if (-not $StatePath) { $StatePath = ($Config -replace '\.json$', '.state.json') }
$logf = Join-Path $env:TEMP "overseer-broker-$($cfg.Broker).log"
function Log($m) { try { Add-Content -LiteralPath $logf -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) } catch {} }
Set-Content -LiteralPath $logf -Value ((Get-Date).ToString('HH:mm:ss.fff') + " START broker=$($cfg.Broker) kind=$Kind") -Encoding UTF8
trap { Log "FATAL $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"; continue }

function Resolve-StartDir {
  $p = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $j = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
      $prof = $j.profiles.list | Where-Object { $_.guid -eq $j.defaultProfile } | Select-Object -First 1
      $sd = $prof.startingDirectory
      if (-not $sd) { $sd = $j.profiles.defaults.startingDirectory }
      if ($sd) { return [Environment]::ExpandEnvironmentVariables($sd) }
    } catch {}
  }
  return $env:USERPROFILE
}

function Get-DescendantPids($root) {
  $out = New-Object System.Collections.Generic.List[int]
  if (-not $root) { return $out }
  $now = [Environment]::TickCount
  if ($script:procCache -and ($now - $script:procStamp) -lt 1500) { $all = $script:procCache }
  else {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $script:procCache = $all; $script:procStamp = $now
  }
  $q = New-Object System.Collections.Generic.Queue[int]
  $out.Add([int]$root); $q.Enqueue([int]$root)
  while ($q.Count -gt 0) {
    $p = $q.Dequeue()
    foreach ($c in ($all | Where-Object { [int]$_.ParentProcessId -eq $p })) {
      $cp = [int]$c.ProcessId
      if (-not $out.Contains($cp)) { $out.Add($cp); $q.Enqueue($cp) }
    }
  }
  return $out
}
function Stop-Descendants($root) {
  for ($pass = 0; $pass -lt 3; $pass++) {
    $script:procCache = $null
    $tree = @(Get-DescendantPids $root)
    Log "stop pass=$pass root=$root tree=$($tree -join ',')"
    if ($tree.Count -le 1 -and $pass -gt 0) { break }
    for ($k = $tree.Count - 1; $k -ge 0; $k--) { Stop-Process -Id $tree[$k] -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
  }
  if ($script:agentPid) { Stop-Process -Id $script:agentPid -Force -ErrorAction SilentlyContinue }
}

function Get-ClaimedTranscripts {
  $out = New-Object System.Collections.Generic.List[string]
  $dir = Join-Path $env:ProgramData 'overseer\brokers'
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.state.json' -File -ErrorAction SilentlyContinue)) {
    if ($f.FullName -eq $StatePath) { continue }
    try {
      $other = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
      if ($other.Transcript) { $out.Add([string]$other.Transcript) }
    } catch {}
  }
  return $out
}
function Set-ClaimedTranscript($path) {
  try {
    [ordered]@{ Transcript = $path } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StatePath -Encoding UTF8
  } catch {}
}
function Test-TranscriptPath($p) {
  return ($p -match '^[A-Za-z]:[\\/][A-Za-z0-9/\\:._ -]*\.jsonl\z')
}
function Resolve-Transcript {
  try {
    if ($Kind -eq 'codex') {
      if ($script:txCache -and (Test-Path -LiteralPath $script:txCache)) { return ($script:txCache -replace '\\', '/') }
      $claimed = @(Get-ClaimedTranscripts)
      $mine = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE '.codex\sessions') -Recurse -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $script:childStart -and $claimed -notcontains $_.FullName } |
        Sort-Object CreationTime | Select-Object -First 1)
      if ($mine) { Set-ClaimedTranscript $mine[0].FullName; $script:txCache = $mine[0].FullName; return ($mine[0].FullName -replace '\\', '/') }
      $script:txCache = ''
      return ''
    }
    if ($Kind -eq 'claude') {
      $ch = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }
      $sid = ''
      foreach ($p in (Get-DescendantPids $script:childPid)) {
        $sf = Join-Path $ch "sessions\$p.json"
        if (Test-Path -LiteralPath $sf) {
          try { $sid = (Get-Content -Raw -LiteralPath $sf | ConvertFrom-Json).sessionId } catch {}
          if ($sid) { break }
        }
      }
      if (-not $sid) { $script:txCache = ''; $script:txSid = ''; return '' }
      if ($script:txSid -eq $sid -and $script:txCache -and (Test-Path -LiteralPath $script:txCache)) { return ($script:txCache -replace '\\', '/') }
      $pd = Join-Path $ch 'projects'
      $f = Get-ChildItem -Path $pd -Recurse -Filter "$sid*.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($f) { $script:txSid = $sid; $script:txCache = $f.FullName; return ($f.FullName -replace '\\', '/') }
      $script:txCache = ''
      return ''
    }
  } catch {}
  return ''
}

$src = @'
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ConIO {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; public COORD(short x, short y){X=x;Y=y;} }
    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode; public ushort UnicodeChar; public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;
    const ushort KEY_EVENT = 1;

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] b, uint len, out uint written);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder b, uint len, COORD c, out uint read);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO i);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleScreenBufferSize(IntPtr h, COORD size);

    public static int GrowBuffer(short rows) {
        IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_SCREEN_BUFFER_INFO i;
        if (!GetConsoleScreenBufferInfo(h, out i)) return -1;
        if (i.dwSize.Y >= rows) return i.dwSize.Y;
        if (!SetConsoleScreenBufferSize(h, new COORD(i.dwSize.X, rows))) return -2;
        return rows;
    }

    static INPUT_RECORD Rec(ushort vk, char c, uint ctrl, bool down) {
        var k = new KEY_EVENT_RECORD();
        k.bKeyDown = down ? 1 : 0; k.wRepeatCount = 1; k.wVirtualKeyCode = vk;
        k.wVirtualScanCode = 0; k.UnicodeChar = (ushort)c; k.dwControlKeyState = ctrl;
        var r = new INPUT_RECORD(); r.EventType = KEY_EVENT; r.KeyEvent = k; return r;
    }
    static uint Emit(List<INPUT_RECORD> recs) {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        if (recs.Count == 0) return 0;
        uint total = 0;
        const int CHUNK = 256;
        for (int off = 0; off < recs.Count; off += CHUNK) {
            int n = Math.Min(CHUNK, recs.Count - off);
            var arr = recs.GetRange(off, n).ToArray();
            uint w;
            WriteConsoleInput(h, arr, (uint)arr.Length, out w);
            total += w;
            if (off + n < recs.Count) Thread.Sleep(4);
        }
        return total;
    }
    public static uint TypeText(string s) {
        var recs = new List<INPUT_RECORD>();
        foreach (char c in s) {
            ushort vk = (c == '\r' || c == '\n') ? (ushort)0x0D : (ushort)0;
            char uc = (c == '\n') ? '\r' : c;
            recs.Add(Rec(vk, uc, 0, true)); recs.Add(Rec(vk, uc, 0, false));
        }
        return Emit(recs);
    }
    public static uint Clear(int rounds) {
        var recs = new List<INPUT_RECORD>();
        for (int k = 0; k < rounds; k++) {
            recs.Add(Rec(0x55, (char)0x15, 0x0008, true)); recs.Add(Rec(0x55, (char)0x15, 0x0008, false));
        }
        return Emit(recs);
    }
    public static uint Paste(string s) {
        string body = s.Replace("\r\n", "\n").Replace("\r", "\n");
        var recs = new List<INPUT_RECORD>();
        for (int k = 0; k < 8; k++) {
            recs.Add(Rec(0x55, (char)0x15, 0x0008, true)); recs.Add(Rec(0x55, (char)0x15, 0x0008, false));
        }
        foreach (char c in body) {
            if (c == '\n') {
                recs.Add(Rec(0x4A, '\n', 0x0008, true)); recs.Add(Rec(0x4A, '\n', 0x0008, false));
            } else {
                recs.Add(Rec(0, c, 0, true)); recs.Add(Rec(0, c, 0, false));
            }
        }
        return Emit(recs);
    }
    public static uint SendKey(ushort vk, char uc, uint ctrl) {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        var arr = new INPUT_RECORD[] { Rec(vk, uc, ctrl, true), Rec(vk, uc, ctrl, false) };
        uint w; WriteConsoleInput(h, arr, 2, out w); return w;
    }
    static string ReadRows(int left, int top, int right, int bottom) {
        IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
        int width = right - left + 1;
        var sb = new StringBuilder();
        for (int y = top; y <= bottom; y++) {
            var line = new StringBuilder(width);
            uint read;
            ReadConsoleOutputCharacter(h, line, (uint)width, new COORD((short)left, (short)y), out read);
            sb.AppendLine(line.ToString(0, (int)read).TrimEnd());
        }
        return sb.ToString();
    }
    public static string Snapshot() {
        IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_SCREEN_BUFFER_INFO i;
        if (!GetConsoleScreenBufferInfo(h, out i)) return "";
        return ReadRows(i.srWindow.Left, i.srWindow.Top, i.srWindow.Right, i.srWindow.Bottom);
    }
    public static string History() {
        IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_SCREEN_BUFFER_INFO i;
        if (!GetConsoleScreenBufferInfo(h, out i)) return "";
        int last = Math.Min(Math.Max(i.dwCursorPosition.Y, i.srWindow.Bottom), i.dwSize.Y - 1);
        return ReadRows(0, 0, i.dwSize.X - 1, last);
    }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
Log "buffer rows=$([ConIO]::GrowBuffer(9999))"

$keymap = @{
  'Enter' = @(0x0D, "`r", 0); 'Escape' = @(0x1B, [char]0x1B, 0); 'Tab' = @(0x09, "`t", 0)
  'Backspace' = @(0x08, [char]0x08, 0); 'Space' = @(0x20, ' ', 0); 'Delete' = @(0x2E, [char]0, 0)
  'Up' = @(0x26, [char]0, 0); 'Down' = @(0x28, [char]0, 0); 'Left' = @(0x25, [char]0, 0); 'Right' = @(0x27, [char]0, 0)
  'Home' = @(0x24, [char]0, 0); 'End' = @(0x23, [char]0, 0); 'PageUp' = @(0x21, [char]0, 0); 'PageDown' = @(0x22, [char]0, 0)
}
function Send-Named($name) {
  if ($name -match '^[Cc]-([a-zA-Z])$') {
    $ch = $Matches[1].ToUpper()[0]
    return [ConIO]::SendKey([ushort][int]$ch, [char]([int]$ch - 64), 0x0008)
  }
  if ($keymap.ContainsKey($name)) {
    $m = $keymap[$name]
    return [ConIO]::SendKey([ushort]$m[0], [char]$m[1], [uint32]$m[2])
  }
  return -1
}
function New-PipeServer {
  $sec = New-Object System.IO.Pipes.PipeSecurity
  foreach ($identity in @($ConsoleUser, 'BUILTIN\Administrators')) {
    $rule = New-Object System.IO.Pipes.PipeAccessRule($identity, [System.IO.Pipes.PipeAccessRights]::ReadWrite, [System.Security.AccessControl.AccessControlType]::Allow)
    $sec.AddAccessRule($rule)
  }
  $acl = 'System.IO.Pipes.NamedPipeServerStreamAcl' -as [type]
  if ($acl) { return $acl::Create($Pipe, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::FirstPipeInstance, 0, 0, $sec) }
  $ctorArgs = @($Pipe, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::FirstPipeInstance, 0, 0, $sec)
  return New-Object -TypeName System.IO.Pipes.NamedPipeServerStream -ArgumentList $ctorArgs
}

$myPid = $PID
$wd = if ($WorkDir) { $WorkDir } else { Resolve-StartDir }
if (-not (Test-Path -LiteralPath $wd)) { $wd = $env:USERPROFILE }
$script:txCache = ''
$script:txSid = ''
$script:procCache = $null
$script:procStamp = 0
$script:agentPid = 0
$script:agentSeen = $false
$script:childStart = (Get-Date).AddSeconds(-5)
$proc = Start-Process -FilePath $Child -ArgumentList $ChildArgs -WorkingDirectory $wd -NoNewWindow -PassThru
Start-Sleep -Milliseconds 1200
$childPid = if ($proc -and $proc.Id) { $proc.Id } else { (Get-CimInstance Win32_Process -Filter "ParentProcessId=$myPid" | Select-Object -First 1).ProcessId }
$script:childPid = $childPid
Log "child exe=$Child kind=$Kind workdir=$wd childPid=$childPid"
function Get-AgentPid {
  if ($Kind -eq 'shell') { return 0 }
  if ($script:agentPid -and (Get-Process -Id $script:agentPid -ErrorAction SilentlyContinue)) { return $script:agentPid }
  $script:agentPid = 0
  foreach ($p in (Get-DescendantPids $script:childPid)) {
    if ($p -eq $script:childPid) { continue }
    $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($pr -and $pr.ProcessName -match '^(claude|codex|node)$') { $script:agentPid = $p; $script:agentSeen = $true; break }
  }
  return $script:agentPid
}
function ChildAlive {
  if (-not $childPid) { return $true }
  if ($Kind -ne 'shell') {
    if (Get-AgentPid) { return $true }
    if ($script:agentSeen) { return $false }
  }
  $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
}

$done = $false
while (-not $done) {
  if (-not (ChildAlive)) { Log 'child exited'; break }
  try { $srv = New-PipeServer } catch { Log "pipe ERR $($_.Exception.Message)"; break }
  $srv.WaitForConnection()
  $r = New-Object System.IO.StreamReader($srv)
  $w = New-Object System.IO.StreamWriter($srv); $w.AutoFlush = $true
  try {
    $auth = $r.ReadLine()
    $want = "AUTH $Token"
    if ($null -eq $auth -or $auth.Length -ne $want.Length -or -not [string]::Equals($auth, $want, [StringComparison]::Ordinal)) { $w.WriteLine('ERR auth'); continue }
    $w.WriteLine('OK auth')
    $client = $true
    while ($client -and $srv.IsConnected) {
      $line = $r.ReadLine()
      if ($null -eq $line) { break }
      $sp = $line.IndexOf(' ')
      if ($sp -lt 0) { $verb = $line; $arg = '' } else { $verb = $line.Substring(0, $sp); $arg = $line.Substring($sp + 1) }
      if ($verb -eq 'TYPE') {
        try { $n = [ConIO]::TypeText([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))); $w.WriteLine("OK $n") }
        catch { $w.WriteLine("ERR type $($_.Exception.Message)") }
      } elseif ($verb -eq 'PASTE') {
        try { $n = [ConIO]::Paste([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))); $w.WriteLine("OK $n") }
        catch { $w.WriteLine("ERR paste $($_.Exception.Message)") }
      } elseif ($verb -eq 'KEY') {
        $n = Send-Named $arg
        if ($n -ge 0) { $w.WriteLine("OK $n") } else { $w.WriteLine("ERR unknown key $arg") }
      } elseif ($verb -eq 'SNAP') {
        $w.WriteLine('<<<SNAP'); $w.Write([ConIO]::Snapshot()); $w.WriteLine('>>>SNAP')
      } elseif ($verb -eq 'CLEAR') {
        try { $n = [ConIO]::Clear(16); $w.WriteLine("OK $n") }
        catch { $w.WriteLine("ERR clear $($_.Exception.Message)") }
      } elseif ($verb -eq 'SNAPALL') {
        $w.WriteLine('<<<SNAP'); $w.Write([ConIO]::History()); $w.WriteLine('>>>SNAP')
      } elseif ($verb -eq 'INFO') {
        $tx = Resolve-Transcript
        if ($tx -and -not (Test-TranscriptPath $tx)) { $tx = '' }
        $w.WriteLine("OK kind=$Kind workdir=$wd childPid=$childPid alive=$(ChildAlive) transcript=$tx")
      } elseif ($verb -eq 'STAT') {
        $tx = Resolve-Transcript
        if ($tx -and -not (Test-TranscriptPath $tx)) { $tx = '' }
        $sz = -1; $mt = 0
        if ($tx) {
          try {
            $fi = Get-Item -LiteralPath ($tx -replace '/', '\') -ErrorAction SilentlyContinue
            if ($fi) { $sz = $fi.Length; $mt = ([DateTimeOffset]$fi.LastWriteTimeUtc).ToUnixTimeSeconds() }
          } catch {}
        }
        $w.WriteLine("OK kind=$Kind alive=$(ChildAlive) size=$sz mtime=$mt transcript=$tx")
      } elseif ($verb -eq 'PING') {
        $w.WriteLine("OK alive=$(ChildAlive)")
      } elseif ($verb -eq 'BYE') {
        $client = $false
      } elseif ($verb -eq 'QUIT') {
        $w.WriteLine('OK quit'); $client = $false; $done = $true
      } else {
        $w.WriteLine("ERR unknown $verb")
      }
    }
  } catch {
    Log "loop ERR $($_.Exception.Message)"
  } finally {
    try { $srv.Dispose() } catch {}
  }
}
Log 'broker exiting'
try { if ($childPid) { Stop-Descendants $childPid } } catch {}
