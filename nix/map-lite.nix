# Provisioning of a factory-default MikroTik mAP lite from the Pi: on boot
# (and periodically) check whether a factory unit is reachable at its default
# 192.168.88.1 over the wired LAN, upload mikrotik/dashchat-map-lite.rsc over
# SFTP, and apply it via `/system reset-configuration run-after-reset=…`.
# Stock RouterOS stays — only its configuration changes. Once provisioned the
# unit moves to the mesh's 10.x addressing, so 192.168.88.1 stops answering
# and the service is a no-op on every later run.
#
# It all happens over ethernet: the factory config bridges ether1 into the LAN
# and serves DHCP there, so the cabled Pi gets a 192.168.88.x lease and reaches
# the router's admin directly — no Wi-Fi, SSID, or login password needed
# (factory admin is passwordless). The applied config re-bridges ether1 into
# the mesh LAN, after which the Pi's ethernet carries all mailbox traffic.
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
      Automatically provision the cabled factory-default MikroTik mAP lite
      into a `dashchat` mesh AP (see mikrotik/dashchat-map-lite.rsc). The unit
      is detected over ethernet at its factory 192.168.88.1 — no credentials
      needed. The broadcast SSID/password come from `dashchat.wifi.{ssid,psk}`,
      overridable per card via `SSID=`/`PASSWORD=` in
      `/boot/firmware/mesh-wifi.env` (whose presence also enables mesh mode;
      without it a cabled mAP is left untouched).
    '';
  };

  config = lib.mkIf cfg.provision {
    systemd.services.map-lite-provision = {
      description = "Provision factory-default MikroTik mAP lite into the dashchat mesh";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      path = [ pkgs.openssh pkgs.sshpass pkgs.iputils pkgs.gawk pkgs.gnused pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -eu

        # Mesh mode is opt-in: with no declared mesh (/boot/firmware/mesh-wifi.env)
        # the appliance is a plain Wi-Fi client (see appliance.nix), so leave any
        # cabled mAP untouched.
        if [ ! -f /boot/firmware/mesh-wifi.env ]; then
          exit 0
        fi

        # HostKeyAlgorithms=+ssh-rsa: RouterOS 6 units only offer a SHA-1 RSA
        # host key, which modern OpenSSH rejects by default.
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password \
          -o HostKeyAlgorithms=+ssh-rsa"

        # Find the wired interface with a carrier — the cable to the mAP lite.
        IFACE=""
        for _ in $(seq 30); do
          for d in /sys/class/net/*; do
            [ -e "$d/wireless" ] && continue
            [ "''${d##*/}" = "lo" ] && continue
            if [ "$(cat "$d/carrier" 2>/dev/null || echo 0)" = "1" ]; then
              IFACE="''${d##*/}"; break
            fi
          done
          [ -n "$IFACE" ] && break
          sleep 1
        done
        if [ -z "$IFACE" ]; then
          exit 0   # no mAP cabled in
        fi

        # The mAP is the DHCP server and the .1 of our subnet in both states:
        # factory (192.168.88.1) and provisioned (10.<B5>.<B6>.1). Derive it
        # from our own lease rather than hardcoding either.
        ROUTER=""
        for _ in $(seq 30); do
          myip=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
            | awk '{ print $4 }' | cut -d/ -f1 | head -n1)
          if [ -n "$myip" ]; then
            ROUTER=$(echo "$myip" | awk -F. '{ print $1 "." $2 "." $3 ".1" }')
            break
          fi
          sleep 1
        done
        if [ -z "$ROUTER" ]; then
          exit 0   # no lease yet; try again next run
        fi

        # Desired mesh network: baked-in default, overridable per card via
        # /boot/firmware/mesh-wifi.env (SSID=… / PASSWORD=…) — the same file the
        # Pi's wifi-provision reads, so the broadcast and joined networks match.
        MESH_SSID=${lib.escapeShellArg config.dashchat.wifi.ssid}
        MESH_PSK=${lib.escapeShellArg config.dashchat.wifi.psk}
        if [ -f /boot/firmware/mesh-wifi.env ]; then
          # shellcheck disable=SC1091
          . /boot/firmware/mesh-wifi.env
          MESH_SSID=''${SSID:-$MESH_SSID}
          MESH_PSK=''${PASSWORD:-$MESH_PSK}
        fi

        # Log in: a factory unit is passwordless; a unit we already provisioned
        # uses the admin password the .rsc sets ("dashchat"). Try both.
        PW=""
        rt() { sshpass -p "$PW" ssh $SSH_OPTS "admin@$ROUTER" "$1"; }
        if ! rt '/system identity print' >/dev/null 2>&1; then
          PW=dashchat
          if ! rt '/system identity print' >/dev/null 2>&1; then
            exit 0   # nothing we recognise at this address
          fi
        fi

        # Re-provision only when the unit isn't already on the desired network,
        # so the 5-minute timer doesn't reset a healthy unit in a loop. This also
        # picks up a changed mesh-wifi.env after a reboot: new SSID/password ->
        # mismatch -> re-provision. A factory unit has no `dashchat` security
        # profile, so cur_psk reads empty and trips the mismatch (first provision).
        cur_ssid=$(rt ':put [/interface wireless get wlan1 ssid]' 2>/dev/null | tr -d '\r\n')
        cur_psk=$(rt ':put [/interface wireless security-profiles get [find name=dashchat] wpa2-pre-shared-key]' 2>/dev/null | tr -d '\r\n')
        if [ "$cur_ssid" = "$MESH_SSID" ] && [ "$cur_psk" = "$MESH_PSK" ]; then
          exit 0
        fi
        echo "Provisioning mAP lite at $ROUTER onto mesh SSID '$MESH_SSID'"

        # Inject the desired SSID/password as RouterOS globals ahead of the
        # config (the .rsc keeps its own defaults for manual imports).
        ros_escape() { sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g'; }
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT
        {
          printf ':global meshssid "%s"\n' "$(printf '%s' "$MESH_SSID" | ros_escape)"
          printf ':global meshpsk "%s"\n'  "$(printf '%s' "$MESH_PSK"  | ros_escape)"
          cat ${rsc}
        } > "$tmp"

        sshpass -p "$PW" scp $SSH_OPTS "$tmp" "admin@$ROUTER:dashchat.rsc"

        # Small-flash devices store uploads under flash/; resolve the actual
        # path before pointing run-after-reset at it (a wrong path would reset
        # into an empty config).
        stored=$(rt '/file print terse where name~"dashchat.rsc"' \
          | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^name=/) { sub(/^name=/, "", $i); print $i; exit } }')
        if [ -z "$stored" ]; then
          echo "uploaded dashchat.rsc not visible on the router; aborting" >&2
          exit 1
        fi

        # The reset drops our session, so a connection error here is expected.
        printf 'y\n' | rt "/system reset-configuration no-defaults=yes skip-backup=yes run-after-reset=$stored" || true
        echo "mAP lite is resetting into the dashchat mesh config ($stored)"
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
