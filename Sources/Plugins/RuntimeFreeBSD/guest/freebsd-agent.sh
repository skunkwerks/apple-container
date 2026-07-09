#!/bin/sh
#
# freebsd-agent.sh — minimal FreeBSD guest agent for the container runtime spike
# (Milestone 2). Speaks newline-delimited JSON (JSONL) over a virtio-console port.
#
# On start it announces a "ready" frame, then answers simple requests:
#   {"op":"ping"}  -> {"event":"pong"}
#   {"op":"uname"} -> {"event":"uname","data":"<uname -a>"}
#
# This is deliberately a shell stub: it proves the bidirectional host<->guest
# channel with zero kernel code and no cross-compiled binary. The production agent
# will replace it (richer protocol, exec/wait, etc.) but use the same transport.
#
# DEVICE: the agent uses the first virtio-console port that is NOT the boot
# console (/dev/ttyV0.0). The exact name depends on the host topology:
#   - Apple VZ exposes two console *devices*       -> agent is /dev/ttyV1.0
#   - a single multi-port virtio-serial (e.g. QEMU -device virtio-serial-pci
#     with two virtconsole ports) -> agent is /dev/ttyV0.1
# We auto-detect below so the same image works under both. Override with
# AGENT_DEV=/dev/ttyVX.Y if needed. Requires virtio_console_load="YES".

# JSON-escape stdin minimally (backslash and double-quote) for embedding in a frame.
json_escape() {
	sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Pick the first virtio-console port that is not the boot console.
pick_dev() {
	for d in /dev/ttyV*; do
		[ -e "$d" ] || continue
		[ "$d" = "/dev/ttyV0.0" ] && continue
		echo "$d"
		return 0
	done
	return 1
}

# Wait for a non-console virtio-console port to appear (it may attach late).
DEV="$AGENT_DEV"
i=0
while [ -z "$DEV" ] && [ "$i" -lt 50 ]; do
	DEV=$(pick_dev) && break
	sleep 0.2
	i=$((i + 1))
done
if [ -z "$DEV" ] || [ ! -e "$DEV" ]; then
	logger -t freebsd-agent "no agent virtio-console device found (need a non-console /dev/ttyV*)"
	exit 1
fi
logger -t freebsd-agent "using agent device $DEV"

# Open the port read/write on fd 3.
exec 3<>"$DEV" || {
	logger -t freebsd-agent "failed to open $DEV"
	exit 1
}

HOSTNAME=$(hostname)
RELEASE=$(uname -r)
printf '{"event":"ready","version":"0.1.0","host":"%s","release":"%s"}\n' \
	"$HOSTNAME" "$RELEASE" >&3

logger -t freebsd-agent "ready on $DEV (host=$HOSTNAME release=$RELEASE)"

# Serve requests line by line until the channel closes.
while IFS= read -r line <&3; do
	case "$line" in
	*'"op":"ping"'*)
		printf '{"event":"pong"}\n' >&3
		;;
	*'"op":"uname"'*)
		U=$(uname -a | json_escape)
		printf '{"event":"uname","data":"%s"}\n' "$U" >&3
		;;
	'')
		: # ignore blank lines
		;;
	*)
		printf '{"event":"error","data":"unknown request"}\n' >&3
		;;
	esac
done

logger -t freebsd-agent "channel closed, exiting"
