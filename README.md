# Raspberry Pi Dash Chat mailbox

A turnkey **NixOS SD-card image for a Raspberry Pi 5** that runs a
[Dash Chat](https://github.com/dash-chat/dash-chat) **mailbox** on your LAN:

- **Mailbox server** — the upstream `mailbox-server` (Axum + redb HTTP blip
  store), reused unmodified.
- **mDNS announce** — publishes itself as `_dashchat._tcp.local.` with its
  `MailboxId` as the instance name, exactly like the desktop app's local-mailbox
  mode, so Dash Chat clients on the same Wi-Fi **auto-discover** it.
- **mDNS discovery + replication** — finds *other* mailboxes on the LAN and runs
  the normal `/blips/get` sync against them, so multiple mailboxes **converge**
  (redundancy / aggregation).

It plugs in, joins your Wi-Fi, and becomes an always-on local mailbox — no cloud,
no configuration beyond Wi-Fi credentials.

## How it works

This repo is **just the NixOS image**. The Rust lives in a **dash-chat branch**
(`feat/local-mailbox-server`, pinned as the `dash-chat` flake input): the
`local-mailbox-server` binary is the `replicating-local-mailbox-server` crate's
bin target, and the mDNS announce/browse logic is the shared
`mailbox-mdns-discovery` crate (also used by the Dash Chat app, so it isn't
duplicated). The binary comes **prebuilt from the dash-chat flake**
(`packages.replicating-local-mailbox-server`, defined next to the crate in
`crates/replicating-local-mailbox-server/default.nix`) — this repo just bakes
it into the image, with no build setup of its own.

| Concern | Where (in the dash-chat branch) |
| --- | --- |
| HTTP server, redb store, identity, blob sync | `crates/mailbox-server` |
| mDNS-announced mailbox server | `crates/mailbox-local-server` |
| Daemon (replication/cloud bridge/blob mirroring + `local-mailbox-server` bin) | `crates/replicating-local-mailbox-server` |
| Shared mDNS announce/browse | `crates/mailbox-mdns-discovery` |

The daemon owns one `redb::Database` handle so the replication loop can read its
watermarks from the same instance — redb allows only one opener per file. To
develop the Rust, work in the dash-chat checkout, push the branch, and `nix
flake update dash-chat` here (or temporarily point the input at the checkout:
`nix flake update dash-chat --override-input dash-chat path:../dash-chat6`).

### Replication scope

Each mailbox syncs the **topics/logs it already knows about**, **bidirectionally**:
it pulls newer blips from each peer and pushes (via the sync protocol's `missing`
report) its own blips the peer lacks. New *authors* within a known topic are
picked up automatically; entirely-new *topics* are seeded by clients that are
members of them, not by replication. See `src/replicate.rs`.

**Blobs (attachments) replicate too.** Since `/blips/get` doesn't carry the blob
hashes a blip references, each mailbox also exposes a small `/blobs/list`
endpoint and **its iroh `EndpointAddr`**; replication teaches iroh that address
(via `BlobSync::add_endpoint_addr`) and fetches over iroh any blob it lacks. A
vanilla peer (e.g. the cloud mailbox) has no such endpoint and is skipped, with
its blobs still resolving to clients peer-to-peer.

Because the peer's direct LAN address is injected into iroh's static address
lookup, **blob transfer works on a purely-offline LAN** (no n0 DNS / internet
needed) — verified by an end-to-end test.

### Cloud bridge

By default the mailbox also replicates with the **production cloud mailbox**
(`https://mailbox.production.darksoil.studio` — the same one the Dash Chat app
uses), bridging LAN traffic to the internet: messages from LAN clients are pushed
up, and cloud messages for known topics are pulled down. It's resolved by its
`/health` endpoint (no mDNS) and needs an internet uplink on the Pi.

Toggle/point it via `services.dashchat-mailbox.cloud.{enable,url}` (see
[`nix/nixos-module.nix`](nix/nixos-module.nix)) — the default production URL lives
there, not in the binary. Set `cloud.enable = false` for a purely-local
deployment. On the binary it's a single optional flag: `--cloud-url <URL>`
(absent = no cloud bridge).

## Powering peripherals (e.g. the mAP lite over USB)

The Pi 5 caps USB-A output at 600 mA unless the firmware is told the
PSU can supply more. [`nix/rpi.nix`](nix/rpi.nix) sets `usb_max_current_enable=1`
in `config.txt` (scoped to `[pi5]`) to unlock up to ~1.6 A shared across USB-A —
enough to power a USB device like the MikroTik mAP lite from the Pi.

## Hardware support / building the image

The image targets the **Raspberry Pi 5** and is built with the
[`nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi) flake, the
community-standard way to run NixOS on Raspberry Pi. It provides the Pi 5 boot
path — the Raspberry Pi vendor kernel (`linux-rpi`) with matched firmware and
device trees, declarative `config.txt`, and the generational bootloader — so
[`nix/rpi.nix`](nix/rpi.nix) only carries appliance-specific tweaks (the CYW43455
Wi-Fi firmware and the `[pi5]` `usb_max_current_enable`). The vendor kernel and
firmware are served prebuilt from the `nixos-raspberrypi.cachix.org` binary
cache, so building the image doesn't compile a kernel from source.

> Cross note: the image is `aarch64-linux`. On an `x86_64` builder you need qemu
> binfmt emulation enabled (NixOS: `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`),
> or a native/remote aarch64 builder. The Rust dependency tree (iroh, p2panda) is
> large; the first build is slow.

```sh
nix build .#sdImage
# → ./result/sd-image/*.img.zst
```

Flash it (Raspberry Pi Imager → "Use custom", or `zstd -d` then `dd`):

```sh
zstd -d result/sd-image/*.img.zst -o mailbox.img
sudo dd if=mailbox.img of=/dev/sdX bs=4M conv=fsync status=progress
```

## Wi-Fi: mesh mode or plain client

Each Pi comes up in one of two modes, chosen at boot by whether a
**`wifi-ap.env`** is present on the FAT **boot partition** (`/boot/firmware`
once running).

**Mesh mode (`wifi-ap.env` present).** The Pi *generates* a Wi-Fi network so
every Pi and phone lands on one LAN and auto-discovers each other. Declare it:

```sh
SSID=dashchat
PASSWORD=dashchat
```

Either line may be omitted to use the baked-in `dashchat.wifi.{ssid,psk}`
defaults ([`nix/appliance.nix`](nix/appliance.nix)). The Pi hosts the network
itself on `wlan0` (AP mode, serving DHCP to connecting phones). Ethernet
doesn't change this — a cabled uplink is just an extra interface, handy for
SSHing into the Pi while the AP runs.

Change the SSID/password by editing `wifi-ap.env` and rebooting.

### Captive portal (AP mode)

When the Pi itself hosts the mesh, devices that join get the OS **"sign in to
network"** screen showing a welcome page: what this network is, live mailbox
status (via the mailbox's `/health`), and how to get started with the Dash Chat
app. Since an AP-mode Pi has no uplink, the page also tells users it's safe to
dismiss the sign-in screen and stay on the mesh.

It works the standard captive-portal way: the AP's DHCP/DNS (NetworkManager's
shared-mode dnsmasq) resolves **every** name to the Pi, nginx answers the OS
connectivity probes (`connectivitycheck.gstatic.com`, `captive.apple.com`,
`msftconnecttest.com`, …) with a redirect to the portal, and the unexpected
answer is what makes phones pop the sign-in screen. A NAT redirect also
catches clients with hardcoded DNS servers. See
[`nix/captive-portal.nix`](nix/captive-portal.nix); disable with
`dashchat.captivePortal.enable = false`.

The page itself is a **Svelte + TypeScript SPA** in [`portal/`](portal/)
(Vite, pnpm), packaged by [`nix/portal.nix`](nix/portal.nix) and served by
nginx at the AP address (`10.42.0.1`, pinned via `dashchat.wifi.apAddress`)
and `http://dashchat-mailbox.local`. To develop it:

```sh
cd portal
pnpm install
pnpm dev     # dev server; /api/* proxies to a local mailbox on :3000
pnpm check   # svelte-check / TypeScript
```

After changing `pnpm-lock.yaml`, refresh the pinned dep hash in
[`nix/portal.nix`](nix/portal.nix) (set it to `lib.fakeHash`, `nix build
.#portal`, copy the real hash from the error).

**Client mode (`wifi-ap.env` absent).** No network is generated — the Pi just
joins an existing one like a normal device. Put its credentials in a
**`wifi.env`** on the boot partition instead:

```sh
SSID=MyNetwork
PASSWORD=mywifipassword
```

Ethernet works out of the box with no configuration; two Pis on the same
switch/router also discover and sync.

## Verifying

From another machine on the same Wi-Fi:

```sh
avahi-browse -rt _dashchat._tcp     # should list the Pi; instance name = 43-char MailboxId
curl http://dashchat-mailbox.local:3000/health
# → {"status":"ok","endpoint_id":"<MailboxId>"}
```

Then open the Dash Chat app on the LAN — it should auto-discover the mailbox.
Stand up a second mailbox (another Pi, or a desktop running local-mailbox mode),
send messages through one, and confirm the other converges.

SSH in as `admin` — `ssh admin@<pi-ip>` (or `ssh admin@dashchat-mailbox.local`
if mDNS resolves). A public key is baked in ([`nix/appliance.nix`](nix/appliance.nix));
password auth (default `dashchat`) is still on as a fallback. Add your own key
there and disable password auth for a locked-down deployment.

## Configuration

The service is a NixOS module — see options under `services.dashchat-mailbox` in
[`nix/nixos-module.nix`](nix/nixos-module.nix) (`addr`, `httpPort`, `serviceType`,
`syncInterval`, `trustedInterfaces`). Appliance basics (hostname,
Wi-Fi, SSH, user) are in [`nix/appliance.nix`](nix/appliance.nix).

## Development

The Rust lives in the dash-chat checkout, built within that workspace (the
`iroh-blobs` patch and version pins apply automatically there):

```sh
cd ../dash-chat6   # the dash-chat branch
cargo test -p replicating-local-mailbox-server
cargo run -p replicating-local-mailbox-server --bin local-mailbox-server -- \
  --db-path ./mailbox.redb --addr '[::]:3000'
```

This repo pins that branch via the `dash-chat` flake input in
[`flake.nix`](flake.nix). After changing the Rust, commit the branch and run
`nix flake update dash-chat` here. Repoint the input URL to a fork/upstream when
the branch is pushed.

## License

The upstream Dash Chat code is AGPL-3.0; this packaging follows suit.
