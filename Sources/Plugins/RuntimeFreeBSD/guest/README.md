# FreeBSD guest agent (Milestone 2 — virtio-console handshake)

These are the **guest-side** artifacts for the virtio-console agent spike. They are
baked into the FreeBSD disk image manually (same workflow as the boot-only
milestone), verified in QEMU first, then exercised by the host helper.

- `freebsd-agent.sh` — the agent: a `/bin/sh` stub that speaks newline-delimited
  JSON over a virtio-console port. It **auto-detects** the port (the first
  `/dev/ttyV*` that isn't the boot console `ttyV0.0`). Announces `ready`, answers
  `ping` and `uname`.
- `freebsd_agent` — an `rc.d` wrapper that launches the agent at boot under
  `daemon(8)`.

The host attaches a second virtio-console for the agent (the first stays the boot
log). The device name depends on host topology, which is why the agent auto-detects:

- **Apple VZ** exposes two console *devices* → agent is **`/dev/ttyV1.0`**.
- A **single multi-port** virtio-serial (e.g. QEMU `-device virtio-serial-pci`
  with two `virtconsole` ports) → agent is **`/dev/ttyV0.1`**.

No guest kernel code is required — `virtio_console(4)` is already in `GENERIC`.

## Prerequisites

`/boot/loader.conf` must load the virtio console driver:

```
virtio_console_load="YES"
```

Do **not** add `if_vtnet_load="YES"` — `vtnet` is built into `GENERIC`, and loading
it as a module triggers `interface vtnet.1 already present in the KLD 'kernel'!`.

For NAT networking under VZ, FreeBSD's `vtnet` needs its feature set relaxed or VZ
rejects negotiation (`virtio_pci0: desired features were not accepted` →
`device_attach: vtnet0 attach returned 45`). Add to `/boot/loader.conf`:

```
hw.vtnet.lro_disable="1"
hw.vtnet.tso_disable="1"
hw.vtnet.csum_disable="1"
hw.vtnet.mq_disable="1"
```

(Confirmed working on FreeBSD 15.1 under Virtualization.framework.)

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

`/dev/ttyV0.0` is the boot-log console; the agent uses the next port
(`/dev/ttyV1.0` under VZ, `/dev/ttyV0.1` under single-device QEMU).

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

## Interactive shell into the guest under VZ (NAT + sshd)

The helper boots headless and VZ has no interactive console, so to get a real shell
under VZ you enable NAT networking on the host side and `sshd` in the guest.

**Host side** — set NAT in the runtime root's `freebsd-vm.json`:

```json
{ "...": "...", "network": "nat" }
```

The helper attaches a `VZNATNetworkDeviceAttachment`; the guest gets an address from
VZ's built-in DHCP (typically `192.168.64.0/24`, host reachable at `.1`).

**Guest side** — bake into the image (via QEMU, where you have a console):

```sh
sysrc ifconfig_vtnet0=DHCP      # VZ's virtio-net NIC is vtnet0
sysrc sshd_enable=YES
passwd root                     # set a password, or install an authorized_keys
```

**Discover the guest IP (headless).** Add to `/etc/rc.local` so it prints to the boot
console (and therefore into `boot.log`):

```sh
ifconfig vtnet0 inet > /dev/ttyV0.0 2>&1
```

Then from the host, after a VZ run:

```sh
grep 'inet ' /tmp/container-freebsd-smoke/boot.log   # find 192.168.64.x
ssh root@192.168.64.x
```

(The host can also consult VZ's lease file at `/var/db/dhcpd_leases`.) The agent
channel and the boot log keep working with NAT enabled — networking is additive.

## Protocol (spike)

Newline-delimited JSON. Guest → host events: `ready`, `pong`, `uname`, `ipaddr`,
`exec`, `error`. Host → guest requests:

- `{"op":"ping"}` → `{"event":"pong"}`
- `{"op":"uname"}` → `{"event":"uname","data":"<uname -a>"}`
- `{"op":"ipaddr"}` → `{"event":"ipaddr","data":"<first non-loopback IPv4 or "">"}`
- `{"op":"exec","cmd64":"<base64 cmd>"}` → `{"event":"exec","code":<int>,"out64":"<base64 combined output>"}`

The exec command and its output are base64-framed (via `openssl base64`) so arbitrary
commands, quotes, and multi-line output survive the one-line JSONL framing. This
intentionally is
*not* gRPC; a raw console stream needs no HTTP/2 framing and JSONL is the smallest
viable handshake. The production agent can later adopt the `SandboxContext` proto
framed over the same console, or move to vsock if it lands in base FreeBSD.
