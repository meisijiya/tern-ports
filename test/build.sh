#!/usr/bin/env bash
# Runs test/run_tests.luau against host.luau with the official luau CLI.
#
# The CLI has no loadfile, no io and no os.getenv, so the three pieces are
# concatenated into one script: the stub from run_tests.luau up to its
# STUB-END anchor, then host.luau with its trailing `return` bound to
# BLOCK_DEF, then the rest of run_tests.luau.
#
# Usage: test/build.sh [path-to-luau]
# The default is $TERNS_LUAU, then a `luau` on PATH, then the WSL copy the
# project uses by default.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
runner="$here/run_tests.luau"
out="${TMPDIR:-/tmp}/tern-ports-tests.luau"

luau="${1:-${TERNS_LUAU:-}}"
if [[ -z "$luau" ]]; then
	if command -v luau >/dev/null 2>&1; then
		luau="$(command -v luau)"
	elif [[ -x /mnt/c/Users/22923/AppData/Local/Temp/luau_bin/luau ]]; then
		# Windows path from a WSL test run; harmless elsewhere.
		luau=/mnt/c/Users/22923/AppData/Local/Temp/luau_bin/luau
	else
		echo "no luau CLI: pass one as \$1 or set \$TERNS_LUAU" >&2
		exit 1
	fi
fi

python3 - "$runner" "$repo/host.luau" "$out" <<'PY'
import sys

runner_path, host_path, out_path = sys.argv[1:4]

with open(runner_path, encoding="utf-8") as fh:
	runner = fh.read()
with open(host_path, encoding="utf-8") as fh:
	host = fh.read()

STUB_END = "-- ==== STUB-END ===="
BLOCK = "-- ==== BLOCK ===="

if STUB_END not in runner or BLOCK not in runner:
	sys.exit("run_tests.luau lost its splice anchors")

stub_end = runner.index(STUB_END) + len(STUB_END)
block_at = runner.index(BLOCK)
if block_at < stub_end:
	sys.exit("BLOCK anchor must come after STUB-END")

# host.luau ends in a bare `return tern.block.define(...)`; the tests want the
# value, so bind it instead of returning it out of the concatenated script.
stripped = host.rstrip()
if not stripped.startswith("--!nocheck") and "return tern.block.define" not in stripped:
	sys.exit("host.luau no longer returns its block definition")
body = stripped.replace(
	"return tern.block.define(",
	"local BLOCK_DEF = tern.block.define(",
	1,
)

pieces = [
	runner[:stub_end],
	"\n\n" + body + "\n\n",
	runner[stub_end:block_at].replace(BLOCK, "", 1),
	runner[block_at:],
]

with open(out_path, "w", encoding="utf-8") as fh:
	fh.write("".join(pieces))
PY

"$luau" "$out"
