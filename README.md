# tern-ports

A [Tern](https://tern.build) plugin that shows every listening TCP port on your
machine and marks the ones an omp process started.

![The Ports block on the `not omp` filter](docs/ports.png)

<!-- The screenshot is the `not omp` filter, so every row is `system`; the omp
     rows only appear under `all` or `omp-launched`. -->

```text
PORT  PID   PROCESS              ADDRESS       PROJECT / CWD      SOURCE
80    5748  httpd.exe            0.0.0.0       - (needs admin)    system
912   6524  vmware-authd.exe     0.0.0.0       - (needs admin)    system
52800 45748 bsk.exe              127.0.0.1     C:\Users\you\blog  omp
```

## Install

```sh
tern plugin install https://github.com/meisijiya/tern-ports
```

or, from a clone, using it where it is:

```sh
tern plugin link /path/to/tern-ports
```

Then open **New Ports block** from the palette, or **New Ports (omp-launched
only) block** for the filtered view. The status line shows the count of
omp-launched services once a scan has run, and turns into an error segment when
the last one failed, so a broken probe never looks like "nothing is listening".

> `window_start` runs once per plugin per window, so a plugin installed while a
> window is already open needs **Tern itself restarted** — a new tab is not
> enough. `tern plugin reload` re-reads the manifest and the host half but does
> not re-run `window_start`, which is where the palette commands and the status
> segment register.

## Keys

| key | what it does |
| --- | --- |
| `f` | cycle filter: all → omp-launched → not omp |
| `r`, `F5` | rescan now (the probe takes 1–2 s; it is not instant) |
| `a` | toggle the 15-second auto-refresh |

The header line carries the keys and the auto state on every row, so they are
discoverable whether or not the table has rows. The filter and the auto flag
survive closing the block.

## Why the omp column exists

An agent that starts a dev server leaves a process tree behind, and finding it
means walking `ParentProcessId` from each listening socket's owner up to the
first `omp` process. A service started through a shell keeps that chain:

```text
bsk.exe < bash.exe < bash.exe < omp.exe
```

Two caveats the plugin does not paper over:

- **omp's own ports are not services.** omp listens on internal IPC sockets.
  Those rows are marked `omp internal` and hidden by the omp filter rather than
  deleted, so the count stays honest.
- **A lost chain is unattributed, not "not omp".** A process reparented by a
  double spawn, or one whose parent already exited, reports `omp = false`
  because nothing was actually found. The `not omp` filter means "no omp
  ancestor found", not "not launched by omp".

## Columns

`PORT` and `PID` carry the highest column priority, which means the *lowest*
hides first — so those two are never dropped. When the pane narrows, `SOURCE`
goes first (`system` repeated down a column says least about any single row),
then `PROJECT / CWD`. At one mid-range width every column is still on screen
and nothing is left to give, and the port number can clip; widening the pane or
narrowing it past that point both avoid it.

`- (needs admin)` in `PROJECT / CWD` means the working directory could not be
read: that needs `PROCESS_VM_READ`, so unelevated it works only for processes
you own. **Run Tern from an elevated shell and the column fills in.**

## How the scan works

`host.luau` runs one platform probe and parses its JSON.

**Windows** (`scripts/ports.ps1`) takes `netstat -ano` for the sockets and one
`Get-CimInstance Win32_Process` snapshot for the process table, which also
feeds the parent walk. Reading a process's real working directory means walking
its PEB through `NtQueryInformationProcess`, because `Get-Process.Path` returns
the *image* directory and reporting an install path as a project's directory
would be a lie.

**Linux and macOS** (`scripts/ports.sh`) take `ss -H -lntp`, or `lsof` on
macOS, and read process details from `ps -A` snapshots. Note the `-A`: on some
WSL images `ps -p` prints a terminal-size notice instead of the row you asked
for.

Both emit the same shape:

```json
{"port":52800,"addr":"127.0.0.1","family":"ipv4","pid":45748,
 "proc":"bsk.exe","cmd":"bsk.exe daemon start",
 "cwd":"C:/Users/you/blog","cwdSource":"process","started":"2026-10-17T07:00:00Z",
 "chain":["bsk.exe","bash.exe","bash.exe","omp.exe"],"omp":true,"ompPid":48332}
```

The ancestry lives in the probe rather than in the block, so the block never
guesses a process tree it was not told about.

## Development

```sh
# 1. edit host.luau / window.luau / plugin.toml
# 2. reload, then restart Tern — reload alone does not re-run window_start
tern plugin reload

# 3. check it against a throwaway window before touching your own
tern --control 8820
tern ctl --control 8820 --file probe.sc
```

`tern --control PORT` opens a window you can drive without disturbing the one
you are working in. Each window runs its own `window_start`, so the commands
and the status segment register there independently — a feature that does not
work in a throwaway window does not work.

### Tests

```sh
bash test/build.sh /path/to/luau
```

`luau` is the official CLI from
[luau-lang/luau](https://github.com/luau-lang/luau/releases) (`luau-ubuntu.zip`
contains the Linux build). The script also accepts `$TERNS_LUAU`, or a `luau` on
`PATH`; there is no machine-specific fallback baked in, because a path that
silently stops matching reads as a broken script rather than a missing CLI.

The block logic runs outside Tern against a stub that reproduces the rule that
matters most: a `cx` is valid only during the call that produced it, and every
`await` retires it. A stub that kept `cx` alive would hide exactly the bug the
suite is there to catch. The CLI has no `loadfile`, `io` or `os.getenv`, so
`test/build.sh` splices the stub, `host.luau` and the runner into one script
between two anchors in `test/run_tests.luau`.

## Licence

MIT
