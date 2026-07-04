# Provisioning of a factory-default MikroTik mAP lite from the Pi.
#
# A factory mAP lite CANNOT be reached over the cable: its single ethernet port
# ships as a firewalled WAN (DHCP client, all inbound management dropped), so
# the only way in is its factory Wi-Fi. On boot (and periodically) the Pi
# therefore borrows wlan0 to join the unit's factory network `MikroTik-XXXXXX`
# (WPA2, per-device sticker password), reaches the router at its LAN address
# 192.168.88.1, uploads mikrotik/dashchat-map-lite.rsc over SFTP, and applies it
# via `/system reset-configuration run-after-reset=…`. Stock RouterOS stays —
# only its configuration changes. Once provisioned the unit drops its factory
# Wi-Fi and comes up broadcasting the mesh, so `MikroTik-XXXXXX` disappears and
# every later run is a no-op.
#
# The sticker credentials come from /boot/firmware/map-lite.env (FACTORY_SSID /
# FACTORY_WIFI_PASSWORD / FACTORY_ADMIN_PASSWORD). We only borrow wlan0 briefly
# and hand it straight back: the provisioned config re-bridges ether1 into the
# mesh LAN, so afterwards the Pi rides the mesh over the cable (wlan0 free) — see
# appliance.nix. That ride, and this provisioning, both require a live carrier on
# the Pi↔mAP cable; without one there is no mAP to adopt and the service is a
# no-op.
{ config, lib, pkgs, ... }:
let
  cfg = config.dashchat.mapLite;
  rsc = ../mikrotik/dashchat-map-lite.rsc;
in
{
  options.dashchat.mapLite.provision = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Automatically adopt a cabled factory-default MikroTik mAP lite into a
      `dashchat` mesh AP (see mikrotik/dashchat-map-lite.rsc). Because a factory
      unit firewalls its ethernet port, the Pi reaches it over its factory
      Wi-Fi using the sticker credentials declared in
      `/boot/firmware/map-lite.env` (`FACTORY_SSID`, `FACTORY_WIFI_PASSWORD`,
      and optionally `FACTORY_ADMIN_PASSWORD` — defaults to the Wi-Fi key; set
      it when the sticker prints a separate login password). The broadcast
      SSID/password come from `dashchat.wifi.{ssid,psk}`, overridable per card
      via `SSID=`/`PASSWORD=` in `/boot/firmware/wifi-ap.env` (whose presence
      also enables mesh mode). Without both env files a cabled mAP is left
      untouched.
    '';
  };

  config = lib.mkIf cfg.provision {
    systemd.services.map-lite-provision = {
      description = "Adopt a factory-default MikroTik mAP lite into the dashchat mesh over its factory Wi-Fi";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      path = [ pkgs.networkmanager pkgs.openssh pkgs.sshpass pkgs.gawk pkgs.gnused pkgs.gnugrep pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -eu

        # Mesh mode is opt-in (/boot/firmware/wifi-ap.env); adopting a mAP also
        # needs its factory credentials (/boot/firmware/map-lite.env). Without
        # either, leave any cabled mAP untouched.
        [ -f /boot/firmware/wifi-ap.env ] || exit 0
        [ -f /boot/firmware/map-lite.env ] || exit 0

        # Factory credentials from the unit's sticker, used once to get in over
        # Wi-Fi. The Wi-Fi key and admin password may be one shared sticker value
        # or two distinct ones; default the admin password to the Wi-Fi key, and
        # set FACTORY_ADMIN_PASSWORD explicitly when the sticker prints two.
        FACTORY_SSID=""
        FACTORY_WIFI_PASSWORD=""
        FACTORY_ADMIN_PASSWORD=""
        # shellcheck disable=SC1091
        . /boot/firmware/map-lite.env
        FACTORY_ADMIN_PASSWORD=''${FACTORY_ADMIN_PASSWORD:-$FACTORY_WIFI_PASSWORD}
        if [ -z "$FACTORY_SSID" ] || [ -z "$FACTORY_WIFI_PASSWORD" ]; then
          echo "map-lite.env is missing FACTORY_SSID/FACTORY_WIFI_PASSWORD; nothing to adopt" >&2
          exit 0
        fi

        # Require a cabled mAP with a live carrier. This mirrors wifi-provision
        # (appliance.nix): carrier up => that service left wlan0 idle, so we can
        # borrow it, and the post-provision ethernet ride will work. No carrier
        # => nothing to adopt.
        have_carrier() {
          for d in /sys/class/net/*; do
            [ -e "$d/wireless" ] && continue
            [ "''${d##*/}" = "lo" ] && continue
            [ "$(cat "$d/carrier" 2>/dev/null || echo 0)" = "1" ] && return 0
          done
          return 1
        }
        carrier=1
        for _ in $(seq 30); do
          have_carrier && { carrier=0; break; }
          sleep 1
        done
        [ "$carrier" = 0 ] || exit 0

        # Desired mesh network: baked-in default, overridable per card via
        # wifi-ap.env — the same file the Pi's wifi-provision reads, so the
        # broadcast and joined networks match.
        MESH_SSID=${lib.escapeShellArg config.dashchat.wifi.ssid}
        MESH_PSK=${lib.escapeShellArg config.dashchat.wifi.psk}
        # shellcheck disable=SC1091
        . /boot/firmware/wifi-ap.env
        MESH_SSID=''${SSID:-$MESH_SSID}
        MESH_PSK=''${PASSWORD:-$MESH_PSK}

        # Is the factory unit actually broadcasting? A provisioned unit shows the
        # mesh SSID, not its factory one, so an absent factory SSID means "no mAP
        # to adopt / already done" — exit quietly (this is the steady state).
        nmcli device wifi rescan ifname wlan0 >/dev/null 2>&1 || true
        sleep 3
        if ! nmcli -t -f SSID device wifi list ifname wlan0 2>/dev/null \
            | grep -Fxq "$FACTORY_SSID"; then
          exit 0
        fi
        echo "Adopting factory mAP lite '$FACTORY_SSID' onto mesh SSID '$MESH_SSID'"

        # Borrow wlan0 to join the factory Wi-Fi (temporary; torn down on exit,
        # whatever happens, so wlan0 is handed back for the ethernet-ride mode).
        tmp=""
        cleanup() {
          nmcli connection down map-lite-adopt >/dev/null 2>&1 || true
          nmcli connection delete map-lite-adopt >/dev/null 2>&1 || true
          [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null || true
        }
        trap cleanup EXIT
        nmcli connection delete map-lite-adopt >/dev/null 2>&1 || true
        nmcli connection add type wifi con-name map-lite-adopt ifname wlan0 \
          ssid "$FACTORY_SSID" autoconnect no
        nmcli connection modify map-lite-adopt \
          wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$FACTORY_WIFI_PASSWORD" \
          ipv4.method auto
        if ! nmcli connection up map-lite-adopt >/dev/null 2>&1; then
          echo "could not join factory Wi-Fi '$FACTORY_SSID'; check FACTORY_WIFI_PASSWORD" >&2
          exit 0
        fi

        # On its factory LAN the mAP is 192.168.88.1 (the Wi-Fi is bridged into
        # that LAN). HostKeyAlgorithms/KexAlgorithms=+…: stock RouterOS offers
        # only legacy SHA-1 host keys / key exchange that modern OpenSSH rejects
        # by default.
        ROUTER=192.168.88.1
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password \
          -o HostKeyAlgorithms=+ssh-rsa \
          -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1"
        rt() { sshpass -p "$FACTORY_ADMIN_PASSWORD" ssh $SSH_OPTS "admin@$ROUTER" "$1"; }

        # Wait for the DHCP lease + admin login (both come good once associated).
        ok=1
        for _ in $(seq 30); do
          if rt '/system identity print' >/dev/null 2>&1; then ok=0; break; fi
          sleep 2
        done
        if [ "$ok" != 0 ]; then
          echo "joined '$FACTORY_SSID' but admin login failed; check FACTORY_ADMIN_PASSWORD" >&2
          exit 0
        fi

        # Inject the desired SSID/password as RouterOS globals ahead of the
        # config (the .rsc keeps its own defaults for manual imports).
        ros_escape() { sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g'; }
        tmp=$(mktemp)
        {
          printf ':global meshssid "%s"\n' "$(printf '%s' "$MESH_SSID" | ros_escape)"
          printf ':global meshpsk "%s"\n'  "$(printf '%s' "$MESH_PSK"  | ros_escape)"
          cat ${rsc}
        } > "$tmp"

        # scp -O: force the legacy SCP protocol. Modern OpenSSH (9+) defaults to
        # SFTP, which stock RouterOS's server rejects ("Connection closed").
        sshpass -p "$FACTORY_ADMIN_PASSWORD" scp -O $SSH_OPTS "$tmp" "admin@$ROUTER:dashchat.rsc"

        # Small-flash devices store uploads under flash/; resolve the actual path
        # before pointing run-after-reset at it (a wrong path would reset into an
        # empty config).
        stored=$(rt '/file print terse where name~"dashchat.rsc"' \
          | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^name=/) { sub(/^name=/, "", $i); print $i; exit } }')
        if [ -z "$stored" ]; then
          echo "uploaded dashchat.rsc not visible on the router; aborting" >&2
          exit 1
        fi

        # The reset drops our Wi-Fi session, so a connection error here is
        # expected.
        printf 'y\n' | rt "/system reset-configuration no-defaults=yes skip-backup=yes run-after-reset=$stored" || true
        echo "mAP lite is resetting into the dashchat mesh config ($stored); it drops '$FACTORY_SSID' and comes up broadcasting '$MESH_SSID', bridged into ether1"
      '';
    };

    systemd.timers.map-lite-provision = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
