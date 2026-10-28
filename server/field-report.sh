#!/usr/bin/env bash
# GripHub field report: what the agent on this server is doing, for the field test (server_agent.md, phase 7).
# Run it as root on the server, then paste the output back:
#
#   sudo bash field-report.sh                      # the last 24 hours
#   sudo bash field-report.sh --since "2 hours ago"
#
# It only reads: the service's state and memory, the host's version, disk and memory of the machine, the box, the
# terminal sessions, warnings from the host's log, and the same for CoderRa's agent when it runs next to it. It prints no
# keys, tokens or file contents; the log lines are the host's own messages. Look it over before you share it anyway.
#
# Options
#   --user NAME     the agent's account (default: griphub)
#   --since TIME    how far back to read the log, in journalctl's words (default: "24 hours ago")
#   --lines N       at most this many log lines (default: 80)
#   -h, --help
set -euo pipefail

USER_NAME=griphub
SINCE="24 hours ago"
LINES=80

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--user) USER_NAME=${2:-}; shift 2 ;;
		--since) SINCE=${2:-}; shift 2 ;;
		--lines) LINES=${2:-}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
done

[[ "$USER_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "--user must be a plain lowercase account name"
[[ "$LINES" =~ ^[0-9]+$ ]] || die "--lines must be a number"
[ "$(id -u)" -eq 0 ] || die "run this as root (sudo bash field-report.sh): it reads another account's service and log"
id "$USER_NAME" >/dev/null 2>&1 || die "no account named $USER_NAME on this server (was bootstrap.sh run? see --user)"

section() { printf '\n## %s\n' "$*"; }
# Runs a command and shows its output, or why there is none; one failing check never stops the report.
show() {
	local out
	if out=$("$@" 2>&1); then
		printf '%s\n' "${out:-(nothing)}"
	else
		printf '(not available: %s)\n' "$(printf '%s' "$out" | tail -n 1)"
	fi
}
# As the agent's account, with its systemd user manager in reach.
as_user() {
	local who=$1
	shift
	local uid
	uid=$(id -u "$who")
	runuser -u "$who" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}
top_processes() { ps -o pid=,rss=,etime=,args= -u "$1" --sort=-rss | head -n 15; }
mib() { awk -v b="${1:-}" 'BEGIN { if (b ~ /^[0-9]+$/) printf "%.0f MiB", b / 1048576; else print "-" }'; }

# The state of one agent: USER, its service, its folder.
agent_report() {
	local who=$1 unit=$2 dir=$3
	local home
	home=$(getent passwd "$who" | cut -d: -f6)
	section "$who: service $unit"
	local props
	if props=$(as_user "$who" systemctl --user show "$unit" \
		-p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp -p MemoryCurrent -p MemoryPeak -p MemoryMax 2>&1); then
		printf '%s\n' "$props" | while IFS='=' read -r k v; do
			case "$k" in
				MemoryCurrent | MemoryPeak | MemoryMax) printf '%s=%s\n' "$k" "$(mib "$v")" ;;
				*) printf '%s=%s\n' "$k" "$v" ;;
			esac
		done
	else
		printf '(not available: %s)\n' "$(printf '%s' "$props" | tail -n 1)"
	fi
	printf 'lingering: %s\n' "$(loginctl show-user "$who" -p Linger --value 2>/dev/null || echo unknown)"

	section "$who: host"
	printf 'version stamp: %s\n' "$(cat "$home/$dir/host/.stamp" 2>/dev/null || echo '(not installed)')"
	printf 'socket: %s\n' "$([ -S "$home/$dir/host.sock" ] && echo present || echo missing)"
	printf 'node: %s\n' "$(command -v node >/dev/null && node -v || echo missing)"
	printf 'processes (pid, rss KiB, running for, command), largest first:\n'
	show top_processes "$who"
	section "$who: data"
	show du -sh "$home/workspace" "$home/.pi/agent/sessions" "$home/$dir"
	printf 'chat sessions: %s\n' "$(find "$home/.pi/agent/sessions" -name '*.jsonl' 2>/dev/null | wc -l)"
	section "$who: terminal sessions (tmux)"
	show as_user "$who" tmux ls
	section "$who: box"
	show as_user "$who" podman images --format '{{.Repository}}:{{.Tag}} {{.Size}} {{.CreatedSince}}'
	show as_user "$who" podman ps --format '{{.Names}} {{.Status}}'
	section "$who: warnings and errors in the log since $SINCE (newest last)"
	show journalctl --no-pager -q -o short-iso --since "$SINCE" -p warning "_SYSTEMD_USER_UNIT=$unit" -n "$LINES"
	section "$who: restarts and notable events since $SINCE"
	show journalctl --no-pager -q -o short-iso --since "$SINCE" "_SYSTEMD_USER_UNIT=$unit" \
		--grep 'restart|memory|disk|kicked|SIGTERM|heap|out of memory|ENOSPC' -n "$LINES"
}

printf '# GripHub field report\n'
printf 'made: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "machine"
# shellcheck source=/dev/null
printf 'os: %s\n' "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
printf 'kernel: %s, %s\n' "$(uname -r)" "$(uname -m)"
printf 'cpus: %s\n' "$(nproc)"
show uptime
show free -m
show df -h / "$(getent passwd "$USER_NAME" | cut -d: -f6)"
printf 'oom kills since %s: %s\n' "$SINCE" "$(journalctl -k --no-pager -q --since "$SINCE" --grep 'Out of memory|oom-kill' 2>/dev/null | wc -l)"

agent_report "$USER_NAME" griphub-hostd.service .griphub

# CoderRa's agent next to it, if it is installed (the field test checks the two side by side).
if id coderra >/dev/null 2>&1; then
	agent_report coderra coderra-hostd.service .coderra
fi

printf '\n# end of report\n'
