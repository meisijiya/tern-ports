#!/bin/sh
# Emits the machine's listening TCP ports as one JSON array.
#
# Same shape as scripts/ports.ps1, so the block parses one format everywhere:
# port, addr, family, pid, proc, cmd, cwd, cwdSource, started, chain, omp,
# ompPid.
#
# A process started by omp through a shell (bash -> node) keeps its parent
# chain and is attributed to omp. A process reparented onto init loses the
# chain and is reported as unattributed rather than guessed either way.
#
# OMP_NAMES overrides the image names counted as omp.

set -u

omp_names="${OMP_NAMES:-omp omp.sh omp-cli}"

have_ss=0
command -v ss >/dev/null 2>&1 && have_ss=1

if [ "$have_ss" -eq 0 ] && ! command -v lsof >/dev/null 2>&1; then
	# Neither tool exists: report an empty machine, not a fake error the
	# block would render as a scan failure.
	echo "[]"
	exit 0
fi

# One `ps -A` snapshot feeds every lookup below. `-A` rather than `-p`: on some
# WSL images `-p` prints a terminal-size notice instead of the requested row,
# and the ancestry walk would otherwise fork `ps` once per ancestor.
ps_all=$(ps -A -o pid=,ppid=,comm= 2>/dev/null || true)
ps_args=$(ps -A -o pid=,args= 2>/dev/null || true)
ps_cwd=$(ps -A -o pid=,cwd= 2>/dev/null || true)
ps_start=$(ps -A -o pid=,lstart= 2>/dev/null || true)

ppid_of() {
	printf '%s\n' "$ps_all" | awk -v want="$1" '$1 == want { print $2; exit }'
}

name_of() {
	printf '%s\n' "$ps_all" | awk -v want="$1" '
		$1 == want { $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }
	'
}

# Each detail comes from its own snapshot: `ps` takes one -o list at a time,
# and a per-pid call costs a fork per field per listening socket.
cmd_of() {
	printf '%s\n' "$ps_args" | awk -v want="$1" '
		$1 == want { $1 = ""; sub(/^[ \t]+/, ""); print; exit }
	'
}

cwd_of() {
	printf '%s\n' "$ps_cwd" | awk -v want="$1" '
		$1 == want { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }
	'
}

started_of() {
	printf '%s\n' "$ps_start" | awk -v want="$1" '
		$1 == want { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }
	'
}

is_omp() {
	base=${1##*/}
	for candidate in $omp_names; do
		[ "$base" = "$candidate" ] && return 0
	done
	return 1
}

# jstr reads a named global rather than $1: a POSIX sh function shares the
# caller's positional parameters, and emit_row's printf passes its own.
esc() {
	raw=$1
	jstr
}

jstr() {
	awk -v s="$raw" 'BEGIN {
		gsub(/\\/, "\\\\", s)
		gsub(/"/, "\\\"", s)
		gsub(/\t/, "\\t", s)
		gsub(/\r/, "\\r", s)
		printf "%s", s
	}'
}

# A POSIX sh function shares its caller's positional parameters, so a `set --`
# anywhere in the pipeline would clobber these arguments. They arrive as named
# globals instead: row_port, row_addr, row_pid.
emit_row() {
	port=$row_port
	addr=$row_addr
	pid=$row_pid

	# Derived here rather than by the caller: two callers with different
	# variable names had already let one row's family leak into the next.
	# Every IPv4 address carries exactly three colons and an IPv6 literal has
	# brackets or more than one colon, so the count decides it — a bare
	# "127.0.0.1:9224" is IPv4 despite ending in a colon.
	colons=$(printf '%s' "$addr" | tr -cd ':' | wc -c)
	case "$addr" in
	[\[\]*)
		family="ipv6"
		;;
	*)
		if [ "$colons" -gt 1 ]; then family="ipv6"; else family="ipv4"; fi
		;;
	esac

	proc=$(name_of "$pid")
	cmd=$(cmd_of "$pid")
	cwd=$(cwd_of "$pid")
	started=$(started_of "$pid")

	# ps prints "-" for a directory it cannot read, which is a placeholder,
	# not a path.
	case "$cwd" in
	'' | '-')
		cwd=""
		cwd_source=""
		;;
	*)
		cwd_source="process"
		;;
	esac

	# Ancestry, innermost first, stopping at the first omp hit or the root.
	chain=""
	omp_pid=0
	cur=$pid
	# Space-delimited with a leading space, and no trailing one, so the
	# membership test below matches exactly one whole pid and not a prefix of
	# another ("65" must not match a seen "653").
	seen=" $pid"
	depth=0
	while [ -n "$cur" ]; do
		# A non-numeric pid (init's 0 on some systems, or a table row the
		# snapshot never had) has to end the walk rather than spin.
		case "$cur" in
		'' | *[!0-9]*) break ;;
		esac
		[ "$cur" -gt 0 ] || break

		case "$seen" in
		*" $cur "*) break ;;
		esac
		seen="$seen $cur"
		own=$(name_of "$cur")
		chain="$chain${chain:+,}\"$(esc "$own")\""
		if [ "$omp_pid" -eq 0 ] && is_omp "$own"; then
			omp_pid=$cur
			break
		fi
		cur=$(ppid_of "$cur")
		depth=$((depth + 1))
		[ "$depth" -gt 64 ] && break
	done

	if [ "$omp_pid" -ne 0 ]; then omp=true; else omp=false; fi

	printf '{"port":%s,"addr":"%s","family":"%s","pid":%s,"proc":"%s","cmd":"%s","cwd":"%s","cwdSource":"%s","started":"%s","chain":[%s],"omp":%s,"ompPid":%s}\n' \
		"$port" "$(esc "$addr")" "$family" "$pid" "$(esc "$proc")" "$(esc "$cmd")" \
		"$(esc "$cwd")" "$cwd_source" "$(esc "$started")" "$chain" "$omp" "$omp_pid"
}

if [ "$have_ss" -eq 1 ]; then
	# With -l, ss prints only listening sockets, so column 1 is the state and
	# column 4 the local address. The pid only appears for processes this user
	# can see; a socket without one is skipped rather than reported without
	# an owner.
	ss -H -lntp 2>/dev/null | while IFS= read -r line; do
		[ -n "$line" ] || continue

		# Field 1 is the state (with -l, ss prints only listening sockets) and
		# field 4 the local address. These are taken with awk rather than
		# `set --`, because a POSIX sh function shares the caller's positional
		# parameters and every helper below reads its own $1.
		parsed=$(printf '%s' "$line" | awk '
			$1 == "LISTEN" {
				addr = $4
				sub(/%.*$/, "", addr)
				col = split(addr, bits, ":")
				port = bits[col]
				pid = ""
				if (match($0, /pid=[0-9]+/)) {
					pid = substr($0, RSTART + 4, RLENGTH - 4)
				}
				if (addr != "" && pid != "") print port "|" addr "|" pid
			}
		')
		[ -n "$parsed" ] || continue

		row_port=${parsed%%|*}
		rest=${parsed#*|}
		row_addr=${rest%%|*}
		row_pid=${rest##*|}
		emit_row
	done
else
	# macOS has no ss. lsof reports the command rather than the pid, so the
	# command is matched back against the ps table to find one.
	lsof -nP -iTCP -sTCP:LISTEN -Fpctn 2>/dev/null | while IFS= read -r line; do
		case "$line" in
		p*)
			pid=${line#p}
			[ -n "$pid" ] || continue
			[ -n "${last_port:-}" ] || continue

			row_port=$last_port
			row_addr=${last_addr:-0.0.0.0}
			row_pid=$pid
			emit_row
			last_port=""
			;;
		t*)
			name=${line#t}
			last_port=$(printf '%s\n' "$ps_all" | awk -v n="$name" '
				{ pid = $1; $1 = ""; $2 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "");
				  if ($0 == n) { found = pid; exit } }
				END { if (found != "") print found }
			')
			;;
		n*)
			last_addr=${line#n}
			;;
		esac
	done
fi | awk '
	BEGIN { printf "["; first = 1 }
	/^\{/ {
		if (!first) printf ","
		first = 0
		printf "%s", $0
	}
	END { printf "]" }
'
