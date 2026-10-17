<#
.SYNOPSIS
Emits the machine's listening TCP ports as one JSON array.

.DESCRIPTION
Every element:
  port       uint16
  addr       string   local bind address as reported
  family     "ipv4" | "ipv6"
  pid        uint32
  proc       string   image name, or "" when the owning pid is gone
  cmd        string   full command line, truncated
  cwd        string   the process's real working directory when readable
  started    string   ISO-8601 process start time, "" when unknown
  chain      string[] ancestor image names, innermost first
  omp        bool     any ancestor is an omp process (see -OmpNames)
  ompPid     uint32   that omp ancestor's pid, 0 when none
  cwdSource  "process" | "image" | ""

A process started by omp through a shell (bash -> node) keeps the parent
chain, so it is attributed to omp. A process reparented by a double spawn
keeps the chain only while the intermediate parent lives; nothing here
guesses past a missing pid, so an unattributed row means "unknown", not
"not omp".

cwd is read from the target's PEB, which needs PROCESS_VM_READ and therefore
fails across user accounts. Those rows fall back to the image directory and
say so through cwdSource; a row with cwdSource "image" is a guess.

.PARAMETER OmpNames
Image names treated as omp processes. Defaults to omp.exe, omp and omp.cmd.
#>
[CmdletBinding()]
param(
	[string[]] $OmpNames = @('omp.exe', 'omp', 'omp.cmd')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# PEB walking. Windows exposes no cmdlet for another process's working
# directory, and image-only fallback reports the install directory, which is
# the wrong answer for "which project is this service".
$script:NatReady = $false
try {
	if (-not ('PortsNative' -as [type])) {
		Add-Type -Namespace PortsNative -Name K -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryInformationProcess(IntPtr h, int c, ref PBI p, int l, out int r);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
[DllImport("kernel32.dll")]
public static extern IntPtr OpenProcess(uint a, bool i, int p);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr h);
[StructLayout(LayoutKind.Sequential)]
public struct PBI {
	public IntPtr Reserved1;
	public IntPtr PebBaseAddress;
	public IntPtr Reserved2_0;
	public IntPtr Reserved2_1;
	public IntPtr UniqueProcessId;
	public IntPtr Reserved3;
}
'@
	}
	$script:NatReady = $true
}
catch { $script:NatReady = $false }

function Read-Ptr($h, [Int64] $addr) {
	$buf = New-Object byte[] 8
	$read = [IntPtr]::Zero
	if (-not [PortsNative.K]::ReadProcessMemory($h, [IntPtr] $addr, $buf, 8, [ref] $read)) { return [IntPtr]::Zero }
	return [IntPtr][BitConverter]::ToInt64($buf, 0)
}

# The PEB's ProcessParameters sits at offset 0x20 on x64; its CurrentDirectory
# is offset 0x38, an RTL_USER_PROCESS_PARAMETERS with UNICODE_STRING at 0x38.
function Get-ProcessCwd([int] $ProcessId) {
	if (-not $script:NatReady) { return '' }
	# QUERY_LIMITED_INFORMATION | QUERY_INFORMATION | VM_READ
	$h = [PortsNative.K]::OpenProcess(0x1410, $false, $ProcessId)
	if ($h -eq [IntPtr]::Zero) { return '' }
	try {
		$pbi = New-Object PortsNative.K+PBI
		$ret = 0
		$status = [PortsNative.K]::NtQueryInformationProcess(
			$h, 0, [ref] $pbi,
			[Runtime.InteropServices.Marshal]::SizeOf([type] 'PortsNative.K+PBI'), [ref] $ret)
		if ($status -ne 0 -or $pbi.PebBaseAddress -eq [IntPtr]::Zero) { return '' }

		$pp = Read-Ptr $h ([Int64] $pbi.PebBaseAddress + 0x20)
		if ($pp -eq [IntPtr]::Zero) { return '' }

		$us = New-Object byte[] 16
		$read = [IntPtr]::Zero
		if (-not [PortsNative.K]::ReadProcessMemory($h, [IntPtr] ([Int64] $pp + 0x38), $us, 16, [ref] $read)) { return '' }

		$len = [BitConverter]::ToUInt16($us, 0)
		$buf = [IntPtr][BitConverter]::ToInt64($us, 8)
		if ($len -eq 0 -or $buf -eq [IntPtr]::Zero) { return '' }

		$chars = New-Object byte[] $len
		if (-not [PortsNative.K]::ReadProcessMemory($h, $buf, $chars, $len, [ref] $read)) { return '' }
		return [Text.Encoding]::Unicode.GetString($chars)
	}
	catch { return '' }
	finally { [void][PortsNative.K]::CloseHandle($h) }
}

function Get-Listeners {
	$raw = & netstat.exe -ano -p TCP 2>$null
	if ($LASTEXITCODE -eq 0 -and $raw) {
		$out = @()
		foreach ($line in $raw) {
			if ($line -notmatch '^\s*TCP\s+(\S+):(\d+)\s+(\S+)\s+LISTENING\s+(\d+)\s*$') { continue }
			$out += [pscustomobject]@{
				addr = $Matches[1]
				port = [int] $Matches[2]
				pid  = [int] $Matches[4]
			}
		}
		return $out
	}

	# Fallback for hosts where netstat is absent or changed its output.
	$out = @()
	foreach ($c in (Get-NetTCPConnection -State Listen)) {
		$out += [pscustomobject]@{
			addr = $c.LocalAddress
			port = [int] $c.LocalPort
			pid  = [int] $c.OwningProcess
		}
	}
	return $out
}

# One CIM snapshot feeds the per-pid detail, the parent walk and start times.
$procs = @{}
foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
	$procs[[int] $p.ProcessId] = [pscustomobject]@{
		pid     = [int] $p.ProcessId
		ppid    = [int] $p.ParentProcessId
		name    = $p.Name
		cmd     = [string] $p.CommandLine
		image   = [string] $p.ExecutablePath
		started = ''
	}
}

try {
	foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId, CreationDate -ErrorAction Stop)) {
		$key = [int] $p.ProcessId
		if ($procs.ContainsKey($key) -and $procs[$key].started -eq '' -and $p.CreationDate) {
			$procs[$key].started = $p.CreationDate.ToUniversalTime().ToString('o')
		}
	}
}
catch { }

$ompSet = @{}
foreach ($n in $OmpNames) { $ompSet[$n.ToLowerInvariant()] = $true }

# Ancestors innermost first. The visited set makes a pid cycle terminate
# instead of spinning, which a malformed table would otherwise cause.
function Get-Ancestry([int] $ProcessId) {
	$chain = @()
	$seen = @{}
	$cur = $ProcessId
	while ($cur -gt 0 -and -not $seen.ContainsKey($cur) -and $chain.Count -lt 64) {
		$seen[$cur] = $true
		$p = $procs[$cur]
		if (-not $p) { break }
		$chain += $p.name
		$cur = $p.ppid
	}
	return $chain
}

function Find-OmpAncestor([int] $ProcessId) {
	$seen = @{}
	$cur = $ProcessId
	while ($cur -gt 0 -and -not $seen.ContainsKey($cur)) {
		$seen[$cur] = $true
		$p = $procs[$cur]
		if (-not $p) { return 0 }
		if ($ompSet.ContainsKey($p.name.ToLowerInvariant())) { return $cur }
		$cur = $p.ppid
	}
	return 0
}

$rows = @()
foreach ($l in (Get-Listeners)) {
	$p = $procs[$l.pid]
	$ompPid = Find-OmpAncestor $l.pid

	$cwd = Get-ProcessCwd $l.pid
	$cwdSource = if ($cwd -ne '') { 'process' } else { '' }
	if ($cwd -eq '' -and $p -and $p.image -ne '') {
		$cwd = Split-Path -Parent $p.image
		$cwdSource = 'image'
	}

	$cmd = if ($p) { [string] $p.cmd } else { '' }
	if ($cmd.Length -gt 400) { $cmd = $cmd.Substring(0, 400) }

	$rows += [pscustomobject]@{
		port      = $l.port
		addr      = $l.addr
		family    = if ($l.addr -match ':') { 'ipv6' } else { 'ipv4' }
		pid       = $l.pid
		proc      = if ($p) { $p.name } else { '' }
		cmd       = $cmd
		cwd       = $cwd
		cwdSource = $cwdSource
		started   = if ($p) { $p.started } else { '' }
		chain     = @(Get-Ancestry $l.pid)
		omp       = ($ompPid -ne 0)
		ompPid    = $ompPid
	}
}

# Stable order: omp first, then port, then pid.
$rows = @($rows | Sort-Object @{ Expression = { if ($_.omp) { 0 } else { 1 } } }, port, pid)

ConvertTo-Json -InputObject $rows -Compress -Depth 4
