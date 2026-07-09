# FreeBSD guest agent (Milestone 2 — virtio-console handshake)

These are the **guest-side** artifacts for the virtio-console agent spike. They are
baked into the FreeBSD disk image manually (same workflow as the boot-only
milestone), verified in QEMU first, then exercised by the host helper.

- `freebsd-agent.sh` — the agent: a `/bin/sh` stub that speaks newline-delimited
  JSON over a virtio-console port (`/dev/ttyV0.1`). Announces `ready`, answers
  `ping` and `uname`.
- `freebsd_agent` — an `rc.d` wrapper that launches the agent at boot under
  `daemon(8)`.

The host attaches a **second port on the same** virtio-console device (the first
port stays the boot log). FreeBSD enumerates it as `/dev/ttyV0.1` (device 0,
port 1). No guest kernel code is required — `virtio_console(4)` is already in
`GENERIC`.

## Prerequisites (already done for boot-only)

`/boot/loader.conf` must load the virtio console driver:

```
virtio_console_load="YES"
```

## Bake-in steps (run inside the guest)

```sh
# 1. Install the agent and its rc.d wrapper
install -m 0755 freebsd-agent.sh /usr/local/sbin/freebsd-agent.sh
install -m 0755 freebsd_agent     /usr/local/etc/rc.d/freebsd_agent

# 2. Enable it
sysrc freebsd_agent_enable=YES

# 3. Confirm the second console device name (adjust AGENT_DEV in the script if
#    your image enumerates it differently)
ls -l /dev/ttyV*
```

`/dev/ttyV0.0` is the boot-log console; `/dev/ttyV0.1` is the agent channel.

## Verify in QEMU first

Add a second virtio-console backed by a UNIX socket to your existing QEMU command
(keep the boot-log `virtconsole` on `vc0`):

```sh
qemu-system-aarch64 -machine virt -accel hvf -cpu host -smp 4 -m 4G -nographic \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/opt/qemu/share/qemu/edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file=/tmp/efivars-arm.fd \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -rtc base=utc -nic user,model=virtio-net-pci \
  -drive if=virtio,format=raw,file=/path/to/FreeBSD-15.1-arm64.raw \
  -device virtio-serial-pci \
  -chardev file,id=vc0,path=/tmp/vtest.log -device virtconsole,chardev=vc0 \
  -chardev socket,id=vc1,path=/tmp/agent.sock,server=on,wait=off \
  -device virtconsole,chardev=vc1
```

In another terminal, connect to the agent socket:

```sh
nc -U /tmp/agent.sock
# You should immediately see:
#   {"event":"ready","version":"0.1.0","host":"freebsd","release":"15.1-RELEASE"}
# Then type a request and press enter:
{"op":"ping"}
#   -> {"event":"pong"}
{"op":"uname"}
#   -> {"event":"uname","data":"FreeBSD freebsd 15.1-RELEASE ..."}
```

If the `ready` frame arrives and `ping`/`uname` round-trip, the channel works.

## Then run under the host helper

Set `"agent": true` in the runtime root's `freebsd-vm.json`, then start the helper.
The helper attaches the second console port automatically and logs:

```
guest agent ready  version=0.1.0 host=freebsd release=15.1-RELEASE
guest agent ping -> pong OK
guest agent uname  uname=FreeBSD freebsd 15.1-RELEASE ...
```

## Protocol (spike)

Newline-delimited JSON. Guest → host events: `ready`, `pong`, `uname`, `error`.
Host → guest requests: `{"op":"ping"}`, `{"op":"uname"}`. This intentionally is
*not* gRPC; a raw console stream needs no HTTP/2 framing and JSONL is the smallest
viable handshake. The production agent can later adopt the `SandboxContext` proto
framed over the same console, or move to vsock if it lands in base FreeBSD.
