# Raspberry Pi Dash Chat mailbox

A turnkey **NixOS SD-card image for a Raspberry Pi 5** that runs a
[Dash Chat](https://github.com/dash-chat/dash-chat) **mailbox** on your LAN:

- **Mailbox server** — the upstream `mailbox-server` (Axum + redb HTTP blip
  store, iroh blob sync), reused unmodified.
- **mDNS announce** — publishes itself as `_dashchat._tcp.local.` with its
  `MailboxId` as the instance name, exactly like the desktop app's local-mailbox
  mode, so Dash Chat clients on the same network **auto-discover** it.

It plugs into the station's network over ethernet and becomes an always-on
local mailbox — no cloud, no configuration.

## Architecture: the Pi doesn't do Wi-Fi

The Wi-Fi network that phones join is hosted by a **MikroTik mAP lite**, not by
the Pi. The Pi is cabled to it over ethernet (plain DHCP client) and powers it
over USB-A — [`nix/rpi.nix`](nix/rpi.nix) sets `usb_max_current_enable=1` in
`config.txt` (scoped to `[pi5]`) to unlock up to ~1.6 A across USB-A, since the
Pi 5 otherwise caps USB-A output at 600 mA. Phones on the mAP lite's Wi-Fi and
the Pi share one LAN, so mDNS discovery just works.

Configure each unit with `just setup-maplite <ssid> <password>`
([`scripts/setup-maplite.sh`](scripts/setup-maplite.sh)): it sets up WPA2 with
the given credentials and bridges the ethernet port into the LAN — the factory
default has it as firewalled WAN, which would hide the Pi from the phones.
First time: join the unit's default `MikroTik-XXXXXX` Wi-Fi (WPA2 password on
the sticker of newer units, open on older) and run it (it prompts for the
unit's admin password — also on the sticker, empty on older units). Keep the SSID/password identical across stations so phones that
joined one auto-join the others.

The Pi's own radio is unused: earlier revisions hosted the AP on the Pi's
brcmfmac chip, which was the main source of field failures (see git history for
the watchdogs it needed). The image is deliberately **minimal** — anything
beyond the mailbox service, ethernet, and SSH must first prove necessary in the
real-hardware e2e tests (`just e2e`, below) before it gets re-added.

## How it works

This repo is **just the NixOS image**. The Rust lives in a **dash-chat branch**
(`develop`, pinned as the `dash-chat` flake input); the image bakes in
its prebuilt `packages.mailbox-local-server` with no build setup of its own.

| Concern | Where (in the dash-chat branch) |
| --- | --- |
| HTTP server, redb store, identity, iroh blob sync | `crates/mailbox-server` |
| mDNS-announced standalone binary (`mailbox-local-server`) | `crates/mailbox-local-server` |

The binary takes just `--db-path` and `--addr`; the NixOS module
([`nix/nixos-module.nix`](nix/nixos-module.nix)) runs it with persistent state
under `/var/lib/dashchat-mailbox` (stable `MailboxId` across reboots) and opens
the firewall for the HTTP API (3000), mDNS (5353), and iroh's dynamic-port
QUIC blob transfer (LAN interfaces trusted). No relay is configured, so the
mailbox is fully local and needs no internet access.

## Building the image

The image targets the **Raspberry Pi 5** and is built with the
[`nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi) flake, which
provides the Pi 5 boot path — the vendor kernel (`linux-rpi`) with matched
firmware and device trees, declarative `config.txt`, and the generational
bootloader — served prebuilt from `nixos-raspberrypi.cachix.org`.

> Cross note: the image is `aarch64-linux`. On an `x86_64` builder you need
> qemu binfmt emulation (NixOS: `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`)
> or a native/remote aarch64 builder. The dash-chat cachix currently carries
> only `x86_64` builds of the server, so the Rust tree (iroh, p2panda) compiles
> under emulation — the first build is slow.

```sh
nix build            # sdImage is the default package
# → ./result/sd-image/*.img.zst
```

Flash it (Raspberry Pi Imager → "Use custom", or with the just recipes):

```sh
just build           # build + decompress to mailbox.img
just devices         # list candidate SD-card devices
just flash           # auto-detect the card and flash (asks before erasing)
```

or by hand: `zstd -d result/sd-image/*.img.zst -o mailbox.img`, then
`sudo dd if=mailbox.img of=/dev/sdX bs=4M conv=fsync status=progress`.

## Verifying: e2e tests against a real Pi

With a flashed Pi cabled to this machine over ethernet:

```sh
just e2e                             # everything, incl. a 20-min longevity soak
just e2e health blips blobs mdns     # just the fast tests
E2E_MINUTES=5 just e2e longevity     # shorter soak
```

The tests ([`scripts/e2e/`](scripts/e2e), one script per test) discover the Pi on the
cable (same mechanism as `ethernet-ssh`) and exercise the mailbox exactly like
the Dash Chat app does, over plain HTTP + mDNS:

- **health** — `GET /health` returns `ok` and a `MailboxId`.
- **blips** — store a blip, fetch it back byte-for-byte (`/blips/store`, `/blips/get`).
- **blobs** — upload a blob, then confirm `/blobs/register-hashes` reports it
  `already_stored` (the server's source of truth for what it holds).
- **mdns** — browse `_dashchat._tcp.local.` and require the instance named by
  the Pi's own `MailboxId`, on the right port.
- **longevity** — a health + blip roundtrip every 20 s for 20 min
  (`E2E_MINUTES` overrides), and the systemd restart counter must not move.

`PI=<addr>` skips discovery; `PI=127.0.0.1 PORT=<port>` smoke-tests a locally
running server.

Manual spot-check from any machine on the same LAN:

```sh
avahi-browse -rt _dashchat._tcp     # instance name = 43-char MailboxId
curl "http://<pi-address>:3000/health"
# → {"status":"ok","endpoint_id":"<MailboxId>", ...}
```

Then open the Dash Chat app on the LAN — it should auto-discover the mailbox.

## Administration

SSH in as `admin` — `ssh admin@<pi-address>`, or over a direct ethernet cable
with the packaged helpers:

```sh
nix run .#find-pi          # discover and print the Pi's address on the cable
nix run .#ethernet-ssh     # discover + open a shell (args become the command)
```

A public key is baked in ([`nix/appliance.nix`](nix/appliance.nix)); password
auth (default `dashchat`) is still on as a fallback. Add your own key there and
disable password auth for a locked-down deployment.

## Configuration

The service is a NixOS module with deliberately few knobs — see
`services.dashchat-mailbox.{enable,package}` in
[`nix/nixos-module.nix`](nix/nixos-module.nix). Appliance basics (hostname,
SSH, admin user) are in [`nix/appliance.nix`](nix/appliance.nix), Pi 5 board
tweaks in [`nix/rpi.nix`](nix/rpi.nix).

## Development

The Rust lives in the dash-chat checkout, built within that workspace:

```sh
cd ../dash-chat6   # the dash-chat branch (develop)
cargo run -p mailbox-local-server -- --db-path ./mailbox.redb --addr '[::]:3000'
```

This repo pins that branch via the `dash-chat` flake input in
[`flake.nix`](flake.nix). After changing the Rust, push the branch and run
`nix flake update dash-chat` here.

## License

The upstream Dash Chat code is AGPL-3.0; this packaging follows suit.
