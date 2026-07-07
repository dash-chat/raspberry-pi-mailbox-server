# Earthquake LARP — design document

A live-action game about carrying information when the network is gone.
Players are couriers in an earthquake-struck town; Raspberry Pi "stations"
running Dash Chat mailboxes are the only communication infrastructure left,
and bots impersonating town characters produce messages that players must
physically carry to their destinations.

This document is the plan of record for what we build next. It builds on what
this repo already provides (the Pi mailbox appliance image) and on the
`dashchat-node` crate from the dash-chat repo (the headless chat node the bots
are built on).

---

## 1. Narrative & game mechanics

An earthquake has hit the town. All networks are down; only a handful of
solar-powered relief stations survived, each hosting a short-range Wi-Fi
mailbox. Worse, the quake opened a cliff straight through town: each member of
a player pair can only move on their own side. The only shared point is the
**base station** on the cliff's edge at the center of the map.

Four characters live at the stations and keep producing urgent messages, each
with a clear recipient ("We detected a fire near Orange Street! Please get
this message to the firefighters!"). Players deliver a message by physically
walking into the destination station's Wi-Fi bubble so their phone syncs it
into that station's mailbox — where the character's bot sees it and replies
with a clear success message ("Okey! Thanks for bringing this to us, we'll get
right on it!"). Messages that originate on the far side of the cliff must be
relayed: carrier walks it to the base station, partner picks it up there and
carries it to the destination.

### Physical layout (2×2 grid, cliff down the middle)

```
   FIREFIGHTERS                          HOSPITAL
   (Pi: AP + mailbox + bot)             (Pi: AP + mailbox + bot)
        ┌────────────────────╥────────────────────┐
        │                    ║                    │
        │    Player A's      ║     Player B's     │
        │      side          ║       side         │
        │                BASE STATION             │
        │            (Pi: AP + mailbox,           │
        │             no bot — reachable          │
        │              from both sides)           │
        │                    ║                    │
        └────────────────────╨────────────────────┘
   RELATIVE (near end)                   JOURNALIST
   (Pi: AP + mailbox + LoRa)            (phone hotspot with internet;
        ~ LoRa link ~                    bot runs on Digital Ocean via
   RELATIVE (far end)                    the existing cloud mailbox)
   (Pi: mailbox + bot + LoRa)
```

Corner assignment is arbitrary — the only requirement is two characters per
side so both players have destinations. The cliff (║) is a rule, not a fence:
players agree not to cross it.

### The cast

| Character | Persona | Infrastructure |
|---|---|---|
| **firefighters** | The fire brigade HQ | Pi 5: Wi-Fi AP + mailbox + bot |
| **hospital** | The town hospital | Pi 5: Wi-Fi AP + mailbox + bot |
| **journalist** | Reporter with a satellite uplink | Phone hotspot (internet); bot on a Digital Ocean droplet syncing through the **existing cloud mailbox** |
| **relative** | Family member in a distant town | Two Pi 5s: the on-map one is AP + mailbox + LoRa bridge; the far-away one runs mailbox + bot + LoRa bridge. Messages to/from the relative take a LoRa round-trip |
| *(base station)* | — (pure relay, no character) | Pi 5: Wi-Fi AP + mailbox only |

Total hardware: **5 × Pi 5** (base, firefighters, hospital, relative-near,
relative-far) + **2 × Heltec V4 LoRa dev kits** (USB-C serial on the two
relative Pis) + **1 phone** (journalist hotspot) + **1 DO droplet** (already
running the cloud mailbox; gains the journalist bot).

### Game setup (briefing, before anyone walks)

1. Each pair adds **each other** as Dash Chat contacts (mutual QR scan, in person).
2. Each player scans the **printed QR sheet** with the four characters'
   contact QR codes and adds all of them as contacts.
3. One player creates a **group** containing: both players + the four characters.
4. The facilitator reads the earthquake framing (also printed on the sheet)
   and sends the pair off, one to each side.

The contact requests and group invitations only *reach* each bot when a player
first syncs at that bot's station — that's fine and thematic: each character
"comes online" when first visited, greets the group in character, and starts
producing missions. There is no separate facilitator trigger (auto-start on
group join was the chosen design).

**Game rule that must be enforced socially:** players keep **mobile data off**
(Wi-Fi on). A phone with LTE would sync everything through the cloud mailbox
from anywhere and short-circuit the entire sneakernet.

### Play loop

1. A bot, for each group it's in, fires a mission message at a random interval
   (default: uniform 3–8 min, configurable), drawn from its character's
   template pool. Every mission names its destination character in the prose
   itself ("…get this message to the firefighters!") — there is **no visible
   machine metadata**; recognition works by author identity + known template
   text (see §3).
2. Players walking into a station's AP bubble auto-sync (Dash Chat's existing
   mDNS local-mailbox discovery) — they pick up whatever blips that mailbox
   holds and deposit whatever they carry.
3. When the destination character's bot sees a mission addressed to it
   (authored by a known cast bot, text matching a template with `to = me`),
   it replies once with that template's in-character success message.
4. The ack travels back through the same courier network, so the pair sees
   their success confirmed in the group chat.

To avoid flooding, a bot caps its **outstanding unacked missions per group**
(default 3) — it pauses its timer until an ack comes back or a timeout passes.

Ending: the facilitator calls time; the group chat itself is the score sheet
(count success replies). No formal end state in software.

---

## 2. What already exists (reused unmodified)

- **This repo's Pi image**: NixOS SD image for Pi 5 with `hostapd` AP
  (range-limited, RSSI-gated), dnsmasq, captive portal, and the
  `replicating-local-mailbox-server` from the dash-chat flake input. Per-card
  configuration via env files on the FAT boot partition (`wifi-ap.env`).
- **mDNS announce/discovery**: stations announce `_dashchat._tcp.local.`, so
  players' apps auto-discover the mailbox when they join a station's Wi-Fi.
- **Mailbox replication** (`replicating-local-mailbox-server`): bidirectional
  `/blips/get` sync of known topics between mailboxes. On this map stations
  are out of each other's range, so LAN replication is idle — but the same
  sync protocol is what we reuse over LoRa (§4).
- **`dashchat-node`** (dash-chat repo): headless node with everything a bot
  needs — `new_qr_code()` / `add_contact()`, auto-join of group invitations
  (already handled in stream processing), `send_message()`, `get_messages()`,
  and a `Notification` mpsc channel that streams every processed operation
  (header + payload) to the embedding application.
- **Cloud mailbox**: already running; the journalist bot and any
  hotspot-connected player sync through it.

## 3. New component: `larp-bot` crate

A new Rust crate **in this repo** (new `crates/` workspace), depending on
`dashchat-node` as a **git dependency pinned to the same rev as the flake's
`dash-chat` input** (the message/payload format must match the app version
players run — version skew here is the #1 way to break the game silently).

One binary, one character per process:

```
larp-bot keygen --out larp-identity.toml           # provision an identity bundle (run on the laptop)
larp-bot qr     --identity larp-identity.toml --out qr.png   # derive the printed QR (offline, no Pi needed)
larp-bot run    --config /etc/larp-bot/config.toml # the daemon (loads the flashed bundle)
```

### Flashable identity (survives wipes and re-flashes)

The character's identity is **not** generated on the Pi — it's a small
**identity bundle** generated once on the laptop and flashed onto each card's
FAT boot partition alongside `wifi-ap.env`/`larp.env`. Re-flashing the image
or wiping `/var/lib/larp-bot` must never invalidate the printed QR sheet.

What has to be in the bundle (all three, or a wipe kills the QR):

- the **device private key** (ed25519 seed — `NodeKeys.private_key`),
- the **agent id** (random, generated once at `keygen` time — upstream derives
  it from a throwaway key on first run, so it's not recoverable from the
  device key),
- the **inbox topic id + expiry** — the printed QR points contact requests at
  this topic, and stream processing drops requests whose topic isn't in the
  local store's `active_inboxes` table. A surviving key with a lost inbox
  topic still means a dead QR.

On every boot the bot loads the bundle from `/boot/firmware/`, passes the
reconstructed `NodeKeys` to `Node::init` (which accepts them directly), and
idempotently re-registers the bundle's inbox topic as active
(`node.local_store` is public, so `add_active_inbox_topic` + topic
initialization need no upstream patch). `/var/lib/larp-bot` is thereby demoted
to a cache: after a wipe the bot forgets group memberships and ack-dedup
state, but players can simply re-scan the *same printed QR* and re-invite it —
the sheet stays valid for the character's lifetime.

The bundle sits plaintext on the FAT partition; for a game prop that's fine.

### Responsibilities

- **Contact QR with long expiry.** The bundle's inbox expiry is set long
  (e.g. 1 year), overriding the short `contact_code_expiry` default. The `qr`
  subcommand derives the `QrCode` (device pubkey, agent id, inbox topic) from
  the bundle alone — so the whole sheet can be printed before any Pi ever
  boots — and must encode it **exactly as the app encodes it** (reuse the
  app's serialization; verify against a real phone scan early).
- **Auto-accept contacts.** Watch the `Notification` stream for
  `InboxPayload::ContactRequest { code, .. }` and call `add_contact(code)` to
  complete the handshake. (Group invitations need nothing: stream processing
  already auto-joins.)
- **Greeting.** On joining a new group, send the character's in-character
  intro line ("This is Mercy Hospital, we're overwhelmed, please help…").
- **Scenario engine.** Per group: a timer loop firing at
  `rand_range(min_interval, max_interval)`, drawing a not-yet-used template
  from the character's pool (reshuffle when exhausted), respecting the
  outstanding-unacked cap.
- **Mission recognition & acks — no visible metadata.** Messages are pure
  in-character prose; the machine layer rides on facts both ends already
  know, since we author every bot:

  - All bots ship with **all four template packs** (they live in this repo)
    and a **cast file**: each character's public agent id, extracted from the
    identity bundles at `keygen` time.
  - *Recipient side:* a group message is a mission for me iff its **author is
    a cast bot's agent id** and its text **exactly matches** a template with
    `to = <my character>`. Then reply once with that template's success line.
    Players typing identical text can't spoof this — they aren't the signing
    author.
  - *Origin side:* a mission counts as delivered when a message **authored by
    the recipient character's agent id** matches that template's success
    line. Success lines must be unique within each pack (enforced by a test),
    and templates never repeat within a group, so the ack→mission mapping is
    unambiguous.
  - *Dedup:* the recipient persists the **header hash** of every mission
    operation it has acked (sqlite/file), so restarts and re-syncs don't
    double-ack. Hashes exist only in the protocol layer — nothing machine-ish
    ever appears on screen.
- **Mailbox wiring.** The node's `Mailboxes` manager is pointed at exactly one
  mailbox URL: `http://127.0.0.1:<port>` on the Pis, the cloud mailbox URL on
  the DO droplet. No iroh internet connectivity is assumed on the Pis (offline
  LAN blob sync already works per this repo's README; missions are text-only
  anyway).

### Configuration (`config.toml`)

```toml
character   = "firefighters"          # persona selection
mailbox_url = "http://127.0.0.1:8080"
identity    = "/boot/firmware/larp-identity.toml"  # flashed bundle (see above)
cast        = "/etc/larp-bot/cast.toml"            # all characters' public agent ids
data_dir    = "/var/lib/larp-bot"                  # cache only — safe to wipe

[timing]
min_interval_secs = 180
max_interval_secs = 480
max_outstanding   = 3

[templates]                            # per-character scenario file
path = "/etc/larp-bot/firefighters.toml"
```

Template file: a list of `{ to = "hospital", text = "…", success = "…" }`
entries plus `greeting`. Authored in Spanish/Catalan/English as needed — pure
content, no code. All four character packs live in this repo under
`scenarios/`, and every bot loads all of them (recognition depends on it —
see above). A unit test lints the packs: `text` and `success` unique across
each pack, `to` values valid.

## 4. New component: `lora-bridge` crate

Carries mailbox sync between the relative's two Pis over **Heltec V4 dev kits
attached via USB-C serial** — beyond Wi-Fi range, no infrastructure.

- **Radio firmware: Meshtastic.** Flash stock Meshtastic on both Heltecs and
  drive them from the Pi over serial using the `meshtastic` Rust crate
  (protobuf API). This buys us LoRa params, framing, ACK/retry and
  region-legal duty-cycle handling (EU868, 1% duty cycle) without writing
  ESP32 firmware. The bridge just exchanges opaque payloads between the two
  fixed node ids. (Fallback if the serial API disappoints: a ~100-line
  transparent serial↔LoRa Arduino sketch with our own framing.)
- **Protocol: the existing replication model, re-transported.** Same
  watermark/digest logic as `replicate.rs` in
  `replicating-local-mailbox-server`, but instead of HTTP `/blips/get` to a
  LAN peer, requests/responses are CBOR + zstd, chunked into ~200-byte LoRa
  frames with sequence numbers and reassembly. Each side talks to *its own
  local* mailbox over HTTP and mirrors the delta to the other side.
- **Scope: text blips only, no blobs.** At LoRa's effective ~1–5 kbps a text
  mission (~300 B compressed) takes seconds — fine. Attachments are out of
  scope for the relative (players learn: "photos don't reach grandma").
- **Topic seeding.** Replication only syncs topics a mailbox already knows.
  The relative-far mailbox knows the group topic because the bot (a member)
  seeds it locally; the relative-near mailbox learns it when the first player
  syncs there. The bridge exchanges topic-id lists in its digest so both sides
  converge on the union.

Deployment: `lora-bridge` runs on both relative Pis (`--serial /dev/ttyACM0
--peer <meshtastic-node-id> --mailbox http://127.0.0.1:8080`).

## 5. NixOS & deployment changes

### One image, per-card station selection

Keep the single-SD-image philosophy: a new **`larp.env`** file on the FAT boot
partition selects the station personality, next to the existing `wifi-ap.env`:

```
STATION=firefighters     # base | firefighters | hospital | relative-near | relative-far
```

New module `nix/larp.nix` (imported by the existing image config) reads it at
boot (same pattern as `wifi-provision`) and enables per-station services:

| STATION | mailbox | AP (hostapd) | larp-bot | lora-bridge |
|---|---|---|---|---|
| `base` | ✓ | ✓ | – | – |
| `firefighters` | ✓ | ✓ | ✓ | – |
| `hospital` | ✓ | ✓ | ✓ | – |
| `relative-near` | ✓ | ✓ | – | ✓ |
| `relative-far` | ✓ | – | ✓ | ✓ |
| *(no larp.env)* | today's plain mailbox appliance, unchanged |

Also per-station: the AP SSID defaults to the station name
(`SSID=larp-firefighters` etc. via `wifi-ap.env`), so the facilitator can see
at a glance which bubble they're in.

`larp-bot` and `lora-bridge` build with `rustPlatform.buildRustPackage` from
this repo's new workspace (git deps of dash-chat handled via `cargoLock`
outputHashes), exposed as flake packages for x86_64 (dev/DO) and aarch64 (Pi).

Provisioning flow (all offline, on the laptop): `larp-bot keygen` once per
character into per-station env dirs (e.g. `env/firefighters/` holding
`wifi-ap.env`, `larp.env`, `larp-identity.toml`); `just flash` already copies
an env dir wholesale onto the FAT boot partition; `larp-bot qr` renders the
printed sheet from the same bundles. `keygen` also emits each character's
public half; those are assembled into `cast.toml`, which is public and
**committed to the repo** and baked into the image for every station.
Bundles themselves are committed nowhere public — they're the characters'
private keys (gitignored, or an untracked `secrets/` dir). The captive portal can additionally serve the station's QR as a
fallback onboarding path.

### Journalist droplet

A small NixOS module (`nix/journalist-do.nix`) + flake `nixosConfiguration`
for the existing droplet: just the `larp-bot` systemd service with
`mailbox_url` set to the cloud mailbox, `character = "journalist"`, and the
journalist's identity bundle deployed as a secret (same `keygen` artifact,
delivered via the droplet's usual secret path instead of a FAT partition). No new
mailbox is deployed (chosen design). The phone hotspot needs zero config — any
internet gets players to the cloud mailbox, which the app already knows about.

## 6. End-to-end message walk-through (sanity check)

Hospital bot fires: *"Injured people trapped on Elm St — get this to the
firefighters!"* into the group topic, via the hospital Pi's localhost
mailbox — plain prose, no visible metadata.

1. Player B (east side) visits the hospital bubble → phone syncs the blip.
2. B walks to the base station → phone deposits it into the base mailbox.
3. Player A (west side) visits base → picks it up.
4. A walks to the firefighters bubble → deposits into the firefighters mailbox.
5. The firefighters bot's node polls its localhost mailbox and sees a message
   authored by the hospital's known agent id whose text matches a template
   with `to = "firefighters"` — it replies *"Okey! Crews dispatched to Elm
   St, thanks!"* (that template's success line).
6. The ack rides the same courier chain back; both players see it, and the
   hospital bot decrements its outstanding count when a message authored by
   the firefighters' agent id matching that success line reaches *its*
   mailbox.

For the relative, steps 4–5 gain a LoRa hop (near-Pi → far-Pi) before the bot
sees it, and the ack hops back. For the journalist, step 4 is "join the
hotspot", the deposit goes to the cloud mailbox, and the DO bot answers
usually within seconds.

## 7. Risks & open questions

- **QR encoding fidelity** — the printed QR must decode in the real app.
  Verify with a phone in week 1; this gates the whole onboarding flow.
- **QR/inbox expiry semantics** — besides the bundle's inbox expiry, check
  that nothing else garbage-collects the bot's inbox topic before game day.
- **Post-wipe state loss** — a wipe preserves identity (flashed bundle) but
  loses group memberships and ack-dedup, so a mid-game re-flash means players
  re-invite the character (same printed QR) and already-acked missions may be
  acked twice. Acceptable; don't wipe mid-game.
- **dashchat-node offline behaviour** — the node embeds iroh/p2panda
  networking that may want internet (relays, DNS). Must verify a node on an
  offline LAN talking only to a localhost mailbox is healthy. (The mailbox
  side is already proven offline; the *node* side is not.)
- **Ack routing asymmetry** — an ack is just another group message; nothing
  guarantees players carry it back. Acceptable (it's gameplay), but templates
  should nudge: "let the hospital know we got this!"
- **Meshtastic serial throughput** — verify real-world frames/minute under
  EU868 duty cycle with a two-device bench test before committing to the
  digest protocol's chattiness; tune digest frequency accordingly.
- **Clocks** — Pi 5 has an RTC header but no battery by default; offline Pis
  wake with wrong time. Blip ordering must not depend on wall clock across
  devices (p2panda ordering is causal, so likely fine — verify), and the
  bot's random timers only need monotonic time. QR expiry comparison uses
  wall clock though — set expiry to years, not days.
- **Player phones auto-leaving the AP** — phones drop Wi-Fi networks with no
  internet. The existing captive portal mitigates; test with the actual
  target phones.

## 8. Implementation milestones

1. **`larp-bot` core** — workspace scaffolding, config, `keygen`/`qr`
   (offline identity bundles), bundle loading + inbox re-registration,
   auto-accept, greeting, scenario engine, mission/ack recognition (author id
   + template matching). E2E test on a laptop:
   two `dashchat-node` test instances + one local mailbox + one bot; assert a
   mission → courier(simulated) → ack round-trip, then wipe the bot's data
   dir, restart it, and assert the same identity/QR still onboards.
2. **Nix integration** — `nix/larp.nix`, `larp.env` station switch,
   per-station env dirs with flashed identity bundles, packages, image build
   for a bot station; live test: phone joins the AP, scans the printed QR,
   creates group, gets greeted, receives mission.
3. **`lora-bridge`** — Meshtastic bench test, then the bridge protocol with a
   mocked serial transport, then the two relative Pis end-to-end.
4. **Journalist droplet** — NixOS config on DO against the cloud mailbox;
   test through a real phone hotspot.
5. **Scenario content + dress rehearsal** — write the four template packs,
   full 5-Pi field test, print the QR sheet, tune intervals/caps.
