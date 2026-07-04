# Appliance basics: hostname, Wi-Fi provisioning, headless SSH.
#
# Wi-Fi has two modes, chosen at boot by whether /boot/firmware/wifi-ap.env
# exists:
#   * present -> "mesh mode": generate the declared network (SSID=/PASSWORD=,
#     falling back to the baked-in defaults below). If a mAP lite is cabled to
#     ethernet it broadcasts the mesh (provisioned by map-lite.nix, reading the
#     same file) and bridges it in over the cable, so wlan0 stays free;
#     otherwise this Pi hosts the mesh itself on wlan0 (AP mode).
#   * absent -> "client mode": just join the network named in
#     /boot/firmware/wifi.env (SSID=/PASSWORD=) like a normal Wi-Fi device.
{ config, lib, pkgs, ... }:
let
  cfg = config.dashchat.wifi;
in
{
  options.dashchat.wifi = {
    ssid = lib.mkOption {
      type = lib.types.str;
      default = "dashchat";
      description = ''
        Default mesh Wi-Fi SSID — the network the mAP lite broadcasts (see
        map-lite.nix), or that a mAP-less Pi hosts itself, when a card opts into
        mesh mode with a `/boot/firmware/wifi-ap.env`. Used whenever that file
        leaves `SSID=` unset; override it there per card, or change this default
        for a private deployment.
      '';
    };
    psk = lib.mkOption {
      type = lib.types.str;
      default = "dashchat"; # WPA2 requires 8-63 chars
      description = ''
        Default mesh Wi-Fi password matching `ssid`. Used whenever
        `/boot/firmware/wifi-ap.env` leaves `PASSWORD=` unset.
      '';
    };
    country = lib.mkOption {
      type = lib.types.str;
      default = "ES";
      description = "Wi-Fi regulatory country code.";
    };
  };

  config = {
    networking.hostName = lib.mkDefault "dashchat-mailbox";

    # NetworkManager (rather than standalone wpa_supplicant) because it tolerates
    # being driven imperatively at runtime and handles autoconnect/priority
    # cleanly. NM drives wpa_supplicant itself over DBus, so we don't set
    # `networking.wireless.enable` directly.
    networking.networkmanager.enable = true;

    systemd.services.wifi-provision = {
      description = "Provision Wi-Fi: mesh mode (wifi-ap.env) hosts/rides the mesh, else client mode joins wifi.env";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.networkmanager pkgs.iw pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu

        add_wifi() { # join an existing network as a client
          name="$1"; ssid="$2"; psk="$3"; prio="$4"
          # Recreate idempotently so config changes take effect on reboot.
          nmcli connection delete "$name" >/dev/null 2>&1 || true
          nmcli connection add type wifi con-name "$name" ifname wlan0 ssid "$ssid"
          nmcli connection modify "$name" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$psk" \
            connection.autoconnect yes \
            connection.autoconnect-priority "$prio"
        }

        add_ap() { # host the network ourselves; NM runs DHCP for clients (phones)
          name="$1"; ssid="$2"; psk="$3"
          nmcli connection delete "$name" >/dev/null 2>&1 || true
          nmcli connection add type wifi con-name "$name" ifname wlan0 ssid "$ssid"
          nmcli connection modify "$name" \
            802-11-wireless.mode ap \
            802-11-wireless.band bg \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$psk" \
            ipv4.method shared \
            connection.autoconnect yes \
            connection.autoconnect-priority 10
        }

        ethernet_link() { # is a mAP lite cabled to our ethernet?
          # Poll briefly, since carrier can take a moment to come up after boot.
          for _ in $(seq 10); do
            for d in /sys/class/net/*; do
              [ -e "$d/wireless" ] && continue
              [ "''${d##*/}" = "lo" ] && continue
              [ "$(cat "$d/carrier" 2>/dev/null || echo 0)" = "1" ] && return 0
            done
            sleep 1
          done
          return 1
        }

        iw reg set ${lib.escapeShellArg cfg.country} 2>/dev/null || true

        # Start clean so a card can switch modes/roles between boots.
        nmcli connection delete dashchat-ap  >/dev/null 2>&1 || true
        nmcli connection delete dashchat-net >/dev/null 2>&1 || true
        nmcli connection delete user-wifi    >/dev/null 2>&1 || true

        if [ -f /boot/firmware/wifi-ap.env ]; then
          # Mesh mode: generate the declared network. SSID=/PASSWORD= come from
          # the file; anything left unset falls back to the baked-in defaults.
          MESH_SSID=${lib.escapeShellArg cfg.ssid}
          MESH_PSK=${lib.escapeShellArg cfg.psk}
          # shellcheck disable=SC1091
          . /boot/firmware/wifi-ap.env
          MESH_SSID=''${SSID:-$MESH_SSID}
          MESH_PSK=''${PASSWORD:-$MESH_PSK}

          if ethernet_link; then
            # A mAP lite is cabled in: it broadcasts the mesh (provisioned by
            # map-lite.nix) and bridges it in over ethernet, so the Pi is already
            # on the network — nothing to host on wlan0. Leaving wlan0 idle also
            # lets map-lite-provision borrow it to adopt a still-factory unit
            # over that unit's Wi-Fi (a factory mAP can't be reached over the
            # cable), then hand it straight back.
            :
          else
            # No mAP: host the mesh on this Pi so phones (and a directly-cabled
            # second Pi) can reach its mailbox.
            add_ap dashchat-ap "$MESH_SSID" "$MESH_PSK"
            nmcli connection up dashchat-ap >/dev/null 2>&1 || true
          fi
        elif [ -f /boot/firmware/wifi.env ]; then
          # Client mode: no mesh declared, so just join the given network like a
          # normal Wi-Fi device. Format:
          #   SSID=MyNetwork
          #   PASSWORD=mypassword
          # shellcheck disable=SC1091
          . /boot/firmware/wifi.env
          if [ -n "''${SSID:-}" ] && [ -n "''${PASSWORD:-}" ]; then
            add_wifi user-wifi "$SSID" "$PASSWORD" 20
            nmcli connection up user-wifi >/dev/null 2>&1 || true
          fi
        fi
      '';
    };

    # --- Headless administration ----------------------------------------------
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = lib.mkDefault true; # set false once you add a key
    };

    # SSH is already reachable over the trusted LAN interfaces, but open 22
    # explicitly so `ssh admin@<pi>` works regardless of which interface the
    # appliance ends up administering itself over (e.g. a non-trusted uplink).
    networking.firewall.allowedTCPPorts = [ 22 ];

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      # Baked-in admin key so we can SSH in to inspect the appliance. Add more
      # keys here (or via the boot partition) and disable PasswordAuthentication
      # above for a locked-down deployment.
      openssh.authorizedKeys.keys = lib.mkDefault [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO8DVpvRgQ90MyMyiuNdvyMNAio9n2o/+57MyhZS2A5A guillem.cordoba@gmail.com"
      ];
      initialPassword = lib.mkDefault "dashchat";
    };
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    documentation.enable = lib.mkDefault false;
    system.stateVersion = lib.mkDefault "25.05";
  };
}
