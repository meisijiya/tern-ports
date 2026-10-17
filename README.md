# tern-ports

A [Tern](https://tern.build) plugin that shows every listening TCP port on your
machine and marks the ones an omp process started.

```text
PORT   ADDRESS        SOURCE   PROCESS        PID  PROJECT / CWD
52800  127.0.0.1      omp      bsk.exe       45748  C:\Users\you\Desktop\blog
64106  127.0.0.1      omp internal  omp.exe   44156  D:\work
3306   0.0.0.0       system   mysqld.exe     7996  C:\Program Files\MySQL
```

## Why the omp column exists

An agent that starts a dev server leaves a process tree behind, and finding it
means walking `ParentProcessId` from each listening socket's owner up to the
first `omp` process. A service started through a shell keeps that chain:

```text
bsk.exe < bash.exe < bash.exe < omp.exe
```

Two caveats the plugin does not paper over:

- **omp's own ports are not services.** omp listens on internal IPC sockets.
  Those rows are marked `omp internal` and hidden by the omp filter rather
  than deleted, so the count stays honest.
- **A lost chain is unattributed, not "not omp".** A process reparented by a
  double spawn, or one whose parent already exited, reports `omp = false`
  because nothing was actually found. The `not omp` filter means "no omp
  ancestor found", not "not launched by omp".

## Install

```sh
tern plugin install https://github.com/meisijiya/tern-ports
```

or from a clone, using it where it is:

```sh
tern plugin link /path/to/tern-ports
```

Then open it from the palette (`New Ports block`) or with `Ctrl+Shift+P` /
`Ctrl+Shift+O` for the omp-only view.

> `window_start` runs once per plugin per window, so a plugin installed into a
> window that is already open needs Tern itself restarted — not a new tab.

## Keys

| key | what it does |
| --- | --- |
| `r`, `F5` | rescan now |
| `f` | cycle filter: all → omp-launched → not omp |
| `a` | toggle the 15-second auto-refresh |

The status line shows the count of omp-launched services once a scan has run,
and turns into an error segment when the last scan failed, so a broken probe
never looks like "nothing is listening".

## How the scan works

`host.luau` runs one platform probe and parses its JSON.

**Windows** (`scripts/ports.ps1`) takes `netstat -ano` for the sockets and one
`Get-CimInstance Win32_Process` snapshot for the process table, which also
feeds the parent walk. Reading a process's real working directory means walking
its PEB through `NtQueryInformationProcess`, because `Get-Process.Path` returns
the *image* directory and reporting an install path as a project's directory
would be a lie. That needs `PROCESS_VM_READ` and so fails across user
accounts; those rows fall back to the image directory and say so through
`cwdSource: "image"`.

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

## Tests

The block logic runs outside Tern, against a stub that reproduces the rule
that matters most: a `cx` is valid only during the call that produced it, and
every `await` retires it. A stub that kept `cx` alive would hide exactly the
bug the suite is there to catch.

```sh
bash test/build.sh /path/to/luau
```

The official `luau` CLI has no `loadfile`, `io` or `os.getenv`, so
`test/build.sh` splices the stub, `host.luau` and the runner into one script
between two anchors in `test/run_tests.luau`.

## Licence

MIT
