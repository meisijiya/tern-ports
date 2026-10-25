#!/usr/bin/env bash
# Runs test/run_tests.luau against host.luau and window.luau with the
# official luau CLI.
#
# The CLI has no loadfile, no io and no os.getenv, so the pieces are
# concatenated into one script per half: the stub from run_tests.luau up to
# its STUB-END anchor, then the half's source, then that half's assertions.
#
# Usage: test/build.sh [path-to-luau]
# The default is $TERNS_LUAU, then a `luau` on PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
runner="$here/run_tests.luau"
out_host="${TMPDIR:-/tmp}/tern-ports-tests-host.luau"
out_window="${TMPDIR:-/tmp}/tern-ports-tests-window.luau"

luau="${1:-${TERNS_LUAU:-}}"
if [[ -z "$luau" ]]; then
	if command -v luau >/dev/null 2>&1; then
		luau="$(command -v luau)"
	else
		# No machine-specific fallback: a path baked in here silently stops
		# matching for everyone who clones, which reads as a broken build
		# script rather than a missing CLI.
		echo "no luau CLI: pass one as \$1 or set \$TERNS_LUAU" >&2
		echo "  download: https://github.com/luau-lang/luau/releases" >&2
		exit 1
	fi
fi

python3 - "$runner" "$repo/host.luau" "$repo/window.luau" "$out_host" "$out_window" <<'PY'
import sys

runner_path, host_path, window_path, out_host_path, out_window_path = sys.argv[1:6]

with open(runner_path, encoding="utf-8") as fh:
	runner = fh.read()
with open(host_path, encoding="utf-8") as fh:
	host = fh.read()
with open(window_path, encoding="utf-8") as fh:
	window = fh.read()

STUB_END = "-- ==== STUB-END ===="
BLOCK = "-- ==== BLOCK ===="
HOST_END = "-- ==== HOST-END ===="
WINDOW_STUB = "-- ==== WINDOW-STUB ===="
WINDOW_BLOCK = "-- ==== WINDOW-BLOCK ===="
WINDOW_END = "-- ==== WINDOW-END ===="
HELPERS = "-- ==== HELPERS ===="
CASES = "-- ==== CASES ===="

for anchor in (
	STUB_END,
	BLOCK,
	HOST_END,
	WINDOW_STUB,
	WINDOW_BLOCK,
	WINDOW_END,
	HELPERS,
	CASES,
):
	if anchor not in runner:
		sys.exit("run_tests.luau lost its splice anchors")

stub_end = runner.index(STUB_END) + len(STUB_END)
block_at = runner.index(BLOCK)
host_end = runner.index(HOST_END)
window_stub_at = runner.index(WINDOW_STUB)
window_block_at = runner.index(WINDOW_BLOCK)
window_end = runner.index(WINDOW_END)
helpers_at = runner.index(HELPERS)
cases_at = runner.index(CASES)

if block_at < stub_end:
	sys.exit("BLOCK anchor must come after STUB-END")
if not stub_end < helpers_at < cases_at < host_end:
	sys.exit("the helper anchors are out of order")
if not host_end < window_stub_at < window_block_at < window_end:
	sys.exit("the window anchors are out of order")

# host.luau registers one block per manifest id with bare tern.block.define
# calls; the stub records them, so the body is spliced in as it stands. What it
# must still contain is the define call the tests read through.
stripped = host.rstrip()
if "tern.block.define(" not in stripped:
	sys.exit("host.luau no longer defines a block")

# The test helpers are shared: the host cases and the window cases both need
# test() and eq().
helpers = runner[helpers_at:cases_at]

host_script = "".join([
	runner[:stub_end],
	"\n\n" + stripped + "\n\n",
	runner[stub_end:block_at].replace(BLOCK, "", 1),
	runner[block_at:host_end],
])

# window.luau ends with a return table, so it is spliced as the body of a
# function expression: the module's exports stay reachable and the entry's
# top-level code runs at entry load, the way a window loads it.
window_script = "".join([
	runner[:stub_end],
	"\n\n",
	helpers,
	"\n\n",
	runner[window_stub_at:window_block_at],
	"\n\nlocal W = (function()\n" + window.rstrip() + "\nend)()\n\n",
	runner[window_block_at:window_end],
])

with open(out_host_path, "w", encoding="utf-8") as fh:
	fh.write(host_script)
with open(out_window_path, "w", encoding="utf-8") as fh:
	fh.write(window_script)
PY

# Both suites run, even when the first one fails: a run that stops at the
# first failure reports less than it could.
#
# A native Windows CLI cannot open a POSIX path. Git Bash converts one on its
# own, WSL needs wslpath and Cygwin has cygpath; a Linux CLI is left alone.
host_arg="$out_host"
window_arg="$out_window"
case "$luau" in
	[A-Za-z]:* | *.exe)
		if command -v cygpath >/dev/null 2>&1; then
			host_arg="$(cygpath -w "$out_host")"
			window_arg="$(cygpath -w "$out_window")"
		elif command -v wslpath >/dev/null 2>&1; then
			host_arg="$(wslpath -w "$out_host")"
			window_arg="$(wslpath -w "$out_window")"
		fi
		;;
esac

status=0
"$luau" "$host_arg" || status=1
"$luau" "$window_arg" || status=1
exit $status
