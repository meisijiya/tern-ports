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

`tern plugin install` copies the package into Tern's plugins directory
(`tern plugin dir`, `%APPDATA%\Tern\plugins` on Windows) and reloads. The
plugin then loads in **every** window, whatever directory that window was
opened in — Tern loads its plugins directory globally, not per project.

Confirm it took:

```sh
tern plugin list      # must end with "ready"
```

To remove it:

```sh
tern plugin remove tern-ports
```

## Working on it

The repository is the source; Tern's plugins directory holds an **installed
copy**. They are two separate trees, and the copy is what actually runs. So a
change needs two steps:

```sh
# 1. edit the repository, then commit
git add -A && git commit -m "fix: ..."

# 2. push the change into Tern's plugins directory
tern plugin install "D:/path/to/tern-ports" --force
```

`--force` replaces an installed copy. Without it the command refuses to touch
one that is already there.

The repository keeps only sources; the shell probe's output is written to a
temporary file at runtime and never lands here.

**Do not develop this with `tern plugin link`.** Linking runs the directory in
place instead of copying it, which makes it ambiguous which tree a running
window is using, and it records an absolute path that breaks the moment the
directory moves or the machine changes. Edit the repository, install the copy.

Then open **New Ports block** from the palette, or **New Ports (omp-launched
only) block** for the filtered view. The status line shows the count of
omp-launched services once a scan has run — the scan runs on its own every 15
seconds, so the status line needs no block to be open — and turns into an
error segment when the last one failed, so a broken probe never looks like
"nothing is listening".

> The window half registers the palette commands and the status segment when
> its entry loads, not on `window_start`: that event runs once per plugin per
> window, and it runs before the window half is loaded, so a handler
> registered there never runs. A reload re-runs the entry, so
> `tern plugin reload` is enough to get the commands and the segment into a
> window that is already open.

## Keys

| key | what it does |
| --- | --- |
| `f` | cycle filter: all → omp-launched → not omp |
| `r`, `F5` | rescan now (the probe takes 1–2 s; it is not instant) |
| `a` | freeze or unfreeze this block on the counts it has |

The header line carries the keys and the auto state on every row, so they are
discoverable whether or not the table has rows. The filter and the auto flag
survive closing the block.

## The status segment

The status segment shows the count of omp-launched services, and it does so
**without the Ports block ever being opened**. The scan that feeds it belongs
to the host half, which starts on its own when the plugin loads:

- the host half scans every **15 seconds** and publishes the counts;
- the window half treats a summary older than **90 seconds** as gone, which
  is six scan periods of slack — so the segment stays as long as the plugin
  is loaded, whether or not a block is open.

The segment's value comes from the window half's own poll cache, not from a
read at redraw time: the poll runs on a timer, keeps the counts it found in
the module, and the status formatter only reads that cache. The live summary
in `last_scan` still carries the port rows — the block needs them — so the
store holds them once, and the formatter never parses them.

A read of the store that fails does not end the polling: the window half
treats it as a transient fault, keeps the summary it already had, and tries
again on the next poll. One half-written `kv.json` therefore costs nothing;
it does not make the segment go quiet ninety seconds later.

Nothing about that is special to the segment: the block and the segment read
the same summary, and the block is only one of its readers. A scan that
belonged to a block used to die with the block, and the segment went quiet
ninety seconds later, which is the shape of the bug this fixed.

**`a` freezes the block, not the scan.** With auto off the block keeps the
counts it had when it was frozen and stops following new ones; the scan keeps
running, so the status segment is unaffected, and a manual `r` / `F5` /
**Rescan** still updates a frozen block — the person at the keyboard always
wins.

`tern.kv` is the only channel between the two halves, and it holds three
keys:

| key | what it is |
| --- | --- |
| `last_scan` | the live summary both halves read: counts, rows, `version`, `at` |
| `last_block_scan` | the host half's own copy, taken when a block is frozen |
| `publisher_lease` | when the last scan ran, so a reloaded plugin does not probe twice as often |

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

# 2. install the edited tree into Tern's plugins directory, which also reloads
tern plugin install "D:/path/to/tern-ports" --force

# 3. check it against a throwaway window before touching your own
tern --control 8820
tern ctl --control 8820 --file probe.sc
```

Step 2 is what makes the edit visible: Tern runs the copy in its plugins
directory, so editing the repository alone changes nothing. A reload re-runs
the plugin entry, which is where the window half registers the palette
commands and the status segment, so a reload brings those back into an open
window. The block definitions are older still: a window opened before the
change can keep them, so restart it, or test in a throwaway window.

`tern --control PORT` opens a window you can drive without disturbing the one
you are working in. Each window loads its own copy of the plugin entry, so the
commands and the status segment register there independently — a feature that
does not work in a throwaway window does not work.

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

The window half gets its own script: the same stub plus the window APIs
(`tern.chrome.status`, `tern.command`, `tern.on`, `tern.timer`), then
`window.luau` spliced as the body of a function expression, so the entry's
top-level code runs at entry load and its exports stay reachable. That suite
dispatches no event at all, so the status segment and the palette commands can
only be there if the entry registered them itself.

## Licence

MIT
