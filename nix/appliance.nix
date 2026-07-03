# Appliance basics: hostname, default mesh Wi-Fi (so all Pis auto-join one
# network and discover each other), optional per-device override, headless SSH.
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
        Default Wi-Fi SSID baked into every image. All Dash Chat mailbox Pis
        join it automatically, so they land on one LAN and auto-discover each
        other. Broadcast this SSID from your access point (e.g. the MikroTik
        mAP lite). Change it (and the AP) for a private deployment.
      '';
    };
    psk = lib.mkOption {
      type = lib.types.str;
      default = "dashchat"; # WPA2 requires 8-63 chars
      description = "Default Wi-Fi password matching `ssid`.";
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
      description = "Provision Wi-Fi: default mesh SSID + optional /boot/firmware/wifi.env";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.networkmanager pkgs.iw ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu

        add_wifi() {
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

        iw reg set ${lib.escapeShellArg cfg.country} 2>/dev/null || true

        # Default mesh network — every Pi flashed from this image joins it, so
        # they auto-discover and replicate with each other with zero config.
        add_wifi dashchat-net ${lib.escapeShellArg cfg.ssid} ${lib.escapeShellArg cfg.psk} 10

        # Optional extra/override network from the boot partition (e.g. your home
        # Wi-Fi for internet). Preferred when present. Format:
        #   SSID=MyNetwork
        #   PSK=mypassword
        if [ -f /boot/firmware/wifi.env ]; then
          # shellcheck disable=SC1091
          . /boot/firmware/wifi.env
          if [ -n "''${SSID:-}" ] && [ -n "''${PSK:-}" ]; then
            add_wifi user-wifi "$SSID" "$PSK" 20
          fi
        fi

        # Connect now; autoconnect also brings it up on later boots / when the AP
        # appears. Non-fatal if the AP isn't in range yet.
        nmcli connection up dashchat-net >/dev/null 2>&1 || true
      '';
    };

    # --- Headless administration ----------------------------------------------
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = lib.mkDefault true; # set false once you add a key
    };

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      # Add your SSH public key here (or via the boot partition) and disable
      # PasswordAuthentication above for a locked-down deployment.
      openssh.authorizedKeys.keys = lib.mkDefault [ ];
      initialPassword = lib.mkDefault "dashchat";
    };
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    documentation.enable = lib.mkDefault false;
    system.stateVersion = lib.mkDefault "25.05";
  };
}
