# Provisioning of a factory-default MikroTik mAP lite from the Pi: on boot
# (and periodically) look for the unit's factory SSID (from `maplite.env` on
# the boot partition), join it, upload mikrotik/dashchat-map-lite.rsc over
# SFTP, and apply it via `/system reset-configuration run-after-reset=…`.
# Stock RouterOS stays — only its configuration changes. Once provisioned the
# factory SSID is gone, so the service is a no-op on every later run.
#
# Provisioning runs over wlan0 even though the Pi is wired to the mAP lite:
# the factory config only allows admin access from the wireless side (ether1
# is its firewalled uplink port). The applied config bridges ether1 into the
# mesh LAN, after which the Pi's ethernet carries all mailbox traffic.
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
      Automatically provision the paired factory-default MikroTik mAP lite
      into a `dashchat` mesh AP (see mikrotik/dashchat-map-lite.rsc). The
      unit is identified by a `maplite.env` on the boot partition holding
      `SSID=…` (its factory network name) and, for units shipped with a
      sticker password, `PASSWORD=…`. Without that file nothing is touched.
    '';
  };

  config = lib.mkIf cfg.provision {
    systemd.services.map-lite-provision = {
      description = "Provision factory-default MikroTik mAP lite into the dashchat mesh";
      after = [ "NetworkManager.service" "wifi-provision.service" ];
      wants = [ "NetworkManager.service" ];
      path = [ pkgs.networkmanager pkgs.openssh pkgs.sshpass pkgs.iputils pkgs.gawk pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -eu

        ROUTER=192.168.88.1
        # HostKeyAlgorithms=+ssh-rsa: RouterOS 6 units only offer a SHA-1 RSA
        # host key, which modern OpenSSH rejects by default.
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password \
          -o HostKeyAlgorithms=+ssh-rsa"
        SSID=""
        PASSWORD=""
        if [ -f /boot/firmware/maplite.env ]; then
          # shellcheck disable=SC1091
          . /boot/firmware/maplite.env
        fi
        if [ -z "$SSID" ]; then
          echo "no SSID in /boot/firmware/maplite.env; nothing to provision"
          exit 0
        fi

        # The factory network (open, MikroTik-XXXXXX) disappears once the unit
        # is provisioned; quietly wait for the next run while it is not around.
        if ! nmcli -t -f SSID dev wifi list ifname wlan0 --rescan yes | grep -qxF "$SSID"; then
          exit 0
        fi
        echo "Found factory mAP lite network $SSID; provisioning"

        cleanup() { nmcli connection delete maplite-setup >/dev/null 2>&1 || true; }
        trap cleanup EXIT
        cleanup
        nmcli connection add type wifi con-name maplite-setup ifname wlan0 \
          ssid "$SSID" connection.autoconnect no >/dev/null
        nmcli connection up maplite-setup >/dev/null

        for _ in $(seq 30); do
          ping -c1 -W1 "$ROUTER" >/dev/null 2>&1 && break
          sleep 1
        done

        rt() { sshpass -p "$PASSWORD" ssh $SSH_OPTS "admin@$ROUTER" "$1"; }

        sshpass -p "$PASSWORD" scp $SSH_OPTS ${rsc} "admin@$ROUTER:dashchat.rsc"

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
