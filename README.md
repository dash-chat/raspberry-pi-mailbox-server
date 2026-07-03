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
duplicated). The flake crane-builds that binary and bakes it into the image.

| Concern | Where (in the dash-chat branch) |
| --- | --- |
| HTTP server, redb store, identity, blob sync | `crates/mailbox-server` |
| mDNS-announced mailbox server | `crates/mailbox-local-server` |
| Daemon (replication/cloud bridge/blob mirroring + `local-mailbox-server` bin) | `crates/replicating-local-mailbox-server` |
| Shared mDNS announce/browse | `crates/mailbox-mdns-discovery` |

The daemon owns one `redb::Database` handle so the replication loop can read its
watermarks from the same instance — redb allows only one opener per file. To
develop the Rust, work in the dash-chat checkout and re-point / `nix flake update
dash-chat` here.

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

The image targets the **Raspberry Pi 5**. The stock `sd-image-aarch64` base only
ships Pi 3/4 boot files, so [`nix/rpi.nix`](nix/rpi.nix) adds what the Pi 5's
EEPROM bootloader needs: the bcm2712 device trees, a Pi 5-capable U-Boot
(`rpi_arm64`) chained via a `[pi5]` `config.txt` stanza, plus the CYW43455
Wi-Fi firmware. It runs the Hydra-cached mainline kernel instead of
nixos-hardware's from-source Raspberry Pi vendor kernel, so building the image
doesn't compile a kernel under emulation. Pi 3/4 would still boot the image via
the stock base's own boot files, but the Pi 5 is the supported target.

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

## Wi-Fi: a shared default network, no per-Pi setup

Every image ships joining a **default mesh Wi-Fi network** so all Pis flashed
from it land on one LAN and auto-discover each other with zero configuration:

| | default |
| --- | --- |
| SSID | `dashchat` |
| password | `dashchat` |

Broadcast that SSID/password from one access point — e.g. a **MikroTik mAP lite**
(or any router/AP) — and every Pi joins it automatically on boot and starts
syncing. Change the defaults (for a private deployment) via the
`dashchat.wifi.{ssid,psk,country}` NixOS options in
[`nix/appliance.nix`](nix/appliance.nix), and set your AP to match.

**Optional per-device override / extra network.** To also put a Pi on another
network (e.g. your home Wi-Fi for internet), drop a **`wifi.env`** on the FAT
**boot partition** (`/boot/firmware` once running):

```sh
SSID=MyNetwork
PSK=mywifipassword
```

It's added as a second, preferred connection — the Pi uses it when in range and
falls back to the mesh network otherwise.

Ethernet works out of the box with no configuration; two Pis on the same
switch/router also discover and sync.

## MikroTik mAP lite: auto-meshing access points

Each Pi is paired with a **mAP lite**: powered from the Pi's USB port (see
[Powering peripherals](#powering-peripherals-eg-the-map-lite-over-usb)) and
**wired to it over ethernet** (mAP `ether1` ↔ Pi ethernet). The provisioned
config bridges `ether1` into the mesh LAN, so the Pi's wired port sits
directly on the merged network — the cable carries all mailbox traffic, while
the Pi's own Wi-Fi is only used to provision the mAP lite (see below) and as a
fallback path. [`mikrotik/dashchat-map-lite.rsc`](mikrotik/dashchat-map-lite.rsc)
provisions every unit identically:

- **AP** broadcasting `dashchat`/`dashchat` (WPA2) — the Pi and any phone
  running Dash Chat join it automatically.
- **Dynamic WDS on a fixed channel**: any two units in range of each other
  automatically form WDS bridge links (same SSID + same channel is the trigger),
  merging their LANs into **one L2 network** — so bringing two kiosks near each
  other is all it takes for their mailboxes to discover each other over mDNS
  and start replicating. RSTP on the bridge breaks the loops a full mesh of
  three or more units creates.
- **Collision-free DHCP**: each unit self-assigns `10.<B5>.<B6>.1/8` and serves
  leases from its own `10.<B5>.<B6>.x` range (B5/B6 = last two bytes of its
  wireless MAC), so the coexisting DHCP servers on a merged mesh hand out
  disjoint addresses within one /8. No gateway/DNS is advertised — the LAN is
  offline-first and phones keep using mobile data for internet.

**The Pi provisions its own mAP lite.** The image ships a `map-lite-provision`
service ([`nix/map-lite.nix`](nix/map-lite.nix)) that runs on boot and every 5
minutes: it joins the paired unit's **factory** network (the open `MikroTik-…`
SSID it broadcasts out of the box), uploads the `.rsc`, and applies it via a
configuration reset. Stock RouterOS stays — only the configuration changes,
same as setting it up by hand. Once provisioned, the factory SSID is gone and
the service does nothing.

The pairing comes from a **`maplite.env`** on the SD card's FAT boot partition
(mount it after flashing, drop the file): the unit's factory SSID, and — for
units that ship with a per-device sticker password — its admin password
(units with a blank factory password can omit it):

```sh
SSID=MikroTik-AB12CD
PASSWORD=AB12CD34
```

Without `maplite.env` the service touches nothing.

Note rpi-imager's own Wi-Fi/password customization fields **cannot** carry
these: the imager writes only hashes to the card (the user password as a crypt
hash, the Wi-Fi passphrase as a derived PSK), and its `firstrun.sh` mechanism
is Raspberry Pi OS-only anyway — the MikroTik login needs the plaintext, so it
travels via `maplite.env`.

Manual fallback (or to customize country `country=spain`, channel
`frequency=2437`, or credentials — all units must share SSID, password, and
channel for the mesh to form): reset the unit (`/system reset-configuration
no-defaults=yes skip-backup=yes`), upload the `.rsc` via WinBox/Files, and
`/import dashchat-map-lite.rsc`.

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

SSH in as `admin` (default password `dashchat` — change it / add a key in
[`nix/appliance.nix`](nix/appliance.nix) and disable password auth).

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
