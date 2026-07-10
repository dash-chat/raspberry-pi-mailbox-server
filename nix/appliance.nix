# Appliance basics: hostname, Wi-Fi provisioning, headless SSH.
#
# Wi-Fi has two modes, chosen at boot by whether /boot/firmware/wifi-ap.env
# exists:
#   * present -> "mesh mode": this Pi hosts the declared network
#     (SSID=/PASSWORD=, falling back to the baked-in defaults below) on wlan0
#     (AP mode, via hostapd). Ethernet is just an extra network interface
#     (e.g. for administering the Pi while the AP runs).
#   * absent -> "client mode": just join the network named in
#     /boot/firmware/wifi.env (SSID=/PASSWORD=) like a normal Wi-Fi device.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashchat.wifi;
  # First three octets of the AP address, for deriving the DHCP range.
  apPrefix = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." cfg.apAddress));
in
{
  options.dashchat.wifi = {
    ssid = lib.mkOption {
      type = lib.types.str;
      default = "dashchat";
      description = ''
        Default mesh Wi-Fi SSID — the network the Pi hosts on wlan0 when a
        card opts into mesh mode with a `/boot/firmware/wifi-ap.env`. Used
        whenever that file leaves `SSID=` unset; override it there per card, or
        change this default for a private deployment.
      '';
    };
    psk = lib.mkOption {
      type = lib.types.str;
      default = "dashchat"; # WPA2 requires 8-63 chars
      description = ''
        Default mesh Wi-Fi password matching `ssid`. Used whenever
        `/boot/firmware/wifi-ap.env` has no `PASSWORD=` line at all; a
        present-but-empty `PASSWORD=` line instead hosts an OPEN network.
      '';
    };
    country = lib.mkOption {
      type = lib.types.str;
      default = "ES";
      description = "Wi-Fi regulatory country code.";
    };
    apAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.1";
      description = ''
        IPv4 address the Pi takes on wlan0 when hosting the mesh (AP mode).
        Pinned (rather than NetworkManager's shared-mode default) so the
        AP's DHCP/DNS config can reference it deterministically.
      '';
    };
  };

  config = {
    networking.hostName = lib.mkDefault "dashchat-mailbox";

    # Stamp the image so `cat /etc/dashchat-version` over SSH settles which
    # build a card actually carries (we've debugged a stale reflash before).
    # Bump when changing Wi-Fi behavior.
    environment.etc."dashchat-version".text =
      "2026-07-09b: drop range limiting (tx clamp, rate floor, RSSI gate, ap-guard) and the captive portal; AP radiates at default power, plain DHCP/DNS\n";

    # NetworkManager (rather than standalone wpa_supplicant) because it tolerates
    # being driven imperatively at runtime and handles autoconnect/priority
    # cleanly. NM drives wpa_supplicant itself over DBus, so we don't set
    # `networking.wireless.enable` directly.
    networking.networkmanager.enable = true;

    # In client mode, always associate with the burned-in hardware MAC (NM's
    # `preserve` default happens to do this today, but pin it): upstream
    # networks may allowlist the Pi by MAC — e.g. a captive-portal hotspot
    # with an ip-binding bypass for a headless mailbox Pi.
    networking.networkmanager.wifi.macAddress = "permanent";

    # NM enables Wi-Fi power save while it still manages wlan0 during early
    # boot (dmesg: repeated "power save enabled" right before the brcmfmac
    # firmware dies ~13 s in, killing the AP under hostapd). Power save on a
    # brcmfmac AP is a known beacon/AP-drop cause — keep it off everywhere;
    # dashchat-ap-radio below re-asserts it on every hostapd start.
    networking.networkmanager.wifi.powersave = false;

    # --- AP mode: hostapd, not NetworkManager ----------------------------------
    # hostapd (rather than NM's AP mode) so the AP config is a plain file we
    # control and the watchdog below can bounce the AP without fighting NM.
    # When this Pi hosts the mesh itself, wifi-provision writes
    # /run/dashchat-ap/hostapd.conf, marks wlan0 as unmanaged and starts these
    # two services. Client modes still go through NM.
    systemd.services.dashchat-hostapd = {
      description = "hostapd for the Pi-hosted mesh AP";
      # No wantedBy: started (and stopped) only by wifi-provision, so a card
      # that switches roles between boots never races a stale AP.
      wants = [
        "dashchat-ap-watchdog.service"
      ];
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "dashchat-ap-addr" ''
          ${pkgs.iproute2}/bin/ip addr replace ${cfg.apAddress}/24 dev wlan0
        '';
        ExecStart = "${pkgs.hostapd}/bin/hostapd /run/dashchat-ap/hostapd.conf";
        # Radio setup once the AP is up: disable power save (power save on a
        # brcmfmac AP silently kills beaconing minutes in — verified live
        # 2026-07-08: with it off the AP stayed up 40+ min vs dying by ~5).
        # Retries because hostapd is still bringing the interface up when
        # ExecStartPost fires.
        ExecStartPost = [
          (pkgs.writeShellScript "dashchat-ap-radio" ''
            for _ in $(seq 10); do
              if ${pkgs.iw}/bin/iw dev wlan0 set power_save off; then
                exit 0
              fi
              sleep 1
            done
            echo "could not disable wlan0 power save" >&2
          '')
          # The mailbox's in-process mDNS responder enumerates interfaces at
          # startup: if it came up while wlan0 was down (early-boot firmware
          # crash) or before the AP address existed, it announces nothing on
          # the mesh and phones can't discover the mailbox. Bounce it on every
          # AP (re)start; no-op when it isn't running yet (boot ordering
          # starts it later, with the AP already up). --no-block: don't hold
          # hostapd's start job on the mailbox restart.
          "${pkgs.systemd}/bin/systemctl --no-block try-restart dashchat-mailbox.service"
        ];
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # The brcmfmac firmware occasionally resets underneath hostapd (observed
    # ~13 s after boot and sporadically minutes later): wlan0 silently
    # degrades from AP to managed/down while hostapd keeps reporting
    # AP-ENABLED, so Restart=on-failure never fires and the SSID just
    # vanishes. hostapd survives the reset unaware; restarting it rebuilds
    # the AP. This watchdog polls the interface and bounces hostapd when it
    # leaves AP mode — without it a cold boot usually comes up with a dead AP.
    systemd.services.dashchat-ap-watchdog = {
      description = "Restart the mesh AP when the Wi-Fi firmware silently drops it";
      bindsTo = [ "dashchat-hostapd.service" ];
      after = [ "dashchat-hostapd.service" ];
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "dashchat-ap-watchdog" ''
          # Two consecutive bad polls so a transient hiccup doesn't trigger a
          # restart. --no-block + exit: this unit is bound to hostapd and is
          # stopped mid-restart; hostapd's wants= starts a fresh watchdog once
          # the AP is back up.
          #
          # Healthy = type AP *and* carrier up: the firmware has died both by
          # flipping the iftype to managed and (2026-07-08, hospital Pi) by
          # keeping "type AP" while the link went NO-CARRIER/DOWN, so either
          # signal alone misses a failure mode. hostapd raises carrier when
          # the AP starts beaconing, so operstate is "up" even with 0 clients.
          healthy() {
            ${pkgs.iw}/bin/iw dev wlan0 info 2>/dev/null | grep -q '^\s*type AP$' || return 1
            [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = up ] || return 1
          }
          sleep 15
          strikes=0
          while sleep 5; do
            if healthy; then
              strikes=0
            else
              strikes=$((strikes + 1))
              if [ "$strikes" -ge 2 ]; then
                echo "wlan0 unhealthy (not type AP with carrier up); restarting dashchat-hostapd"
                ${pkgs.systemd}/bin/systemctl --no-block restart dashchat-hostapd.service
                exit 0
              fi
            fi
          done
        '';
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # DHCP + DNS for AP clients (NM's shared mode provided these; hostapd does
    # not).
    environment.etc."dashchat-ap/dnsmasq.conf".text = ''
      port=53
      interface=wlan0
      bind-dynamic
      no-resolv
      dhcp-range=${apPrefix}.10,${apPrefix}.250,12h
      dhcp-option=option:router,${cfg.apAddress}
      dhcp-option=option:dns-server,${cfg.apAddress}
      dhcp-authoritative
    '';

    systemd.services.dashchat-ap-dnsmasq = {
      description = "DHCP/DNS for the Pi-hosted mesh AP";
      after = [ "dashchat-hostapd.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/etc/dashchat-ap/dnsmasq.conf";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # The mailbox's mDNS responder enumerates interface addresses once at
    # startup. The hostapd ExecStartPost bounce above covers AP (re)starts,
    # but on the plain boot path the mailbox can still first-start while
    # wlan0 is address-less (network-online is satisfied by ethernet
    # alone) and announce nothing usable on the mesh — wifi works but
    # phones never find the mailbox (diagnosed 2026-07-10). Hold the start
    # until wlan0 holds an IPv4; give up after 30 s so cards without wifi,
    # or in client mode with no network in range, still boot.
    systemd.services.dashchat-mailbox = {
      after = [ "dashchat-hostapd.service" ];
      preStart = ''
        [ -e /sys/class/net/wlan0 ] || exit 0
        for _ in $(${pkgs.coreutils}/bin/seq 30); do
          [ -z "$(${pkgs.iproute2}/bin/ip -4 -o addr show dev wlan0)" ] || exit 0
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "wlan0 still has no IPv4 after 30s; starting anyway" >&2
      '';
    };

    networking.firewall.interfaces.wlan0 = {
      allowedUDPPorts = [
        53
        67
      ]; # AP-mode DNS + DHCP
      allowedTCPPorts = [ 53 ];
    };

    systemd.services.wifi-provision = {
      description = "Provision Wi-Fi: mesh mode (wifi-ap.env) hosts the mesh AP, else client mode joins wifi.env";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.networkmanager
        pkgs.iw
        pkgs.coreutils
        pkgs.iproute2
        pkgs.systemd
      ];
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

        add_ap() { # host the network ourselves: hostapd + dnsmasq, wlan0 out of NM's hands
          ssid="$1"; psk="$2"
          mkdir -p /run/dashchat-ap
          # Quoted delimiter: an SSID/PSK containing $ or backticks must land
          # in the config verbatim, so those go in via printf below.
          cat > /run/dashchat-ap/hostapd.conf <<'EOF'
        interface=wlan0
        driver=nl80211
        ctrl_interface=/run/dashchat-ap

        # 2.4 GHz so that cheap/old 2.4-only devices can still join.
        country_code=${cfg.country}
        ieee80211d=1
        hw_mode=g
        channel=1
        wmm_enabled=1
        EOF
          printf 'ssid=%s\n' "$ssid" >> /run/dashchat-ap/hostapd.conf
          # Empty psk -> open network (hostapd defaults to wpa=0).
          if [ -n "$psk" ]; then
            printf 'wpa=2\nwpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP\nwpa_passphrase=%s\n' "$psk" >> /run/dashchat-ap/hostapd.conf
          fi
          chmod 600 /run/dashchat-ap/hostapd.conf
          nmcli device set wlan0 managed no >/dev/null 2>&1 || true
          systemctl restart dashchat-hostapd.service dashchat-ap-dnsmasq.service
        }

        iw reg set ${lib.escapeShellArg cfg.country} 2>/dev/null || true

        # Start clean so a card can switch modes/roles between boots.
        systemctl stop dashchat-hostapd.service dashchat-ap-dnsmasq.service >/dev/null 2>&1 || true
        nmcli connection delete dashchat-ap  >/dev/null 2>&1 || true # pre-hostapd images
        nmcli connection delete dashchat-net >/dev/null 2>&1 || true
        nmcli connection delete user-wifi    >/dev/null 2>&1 || true
        nmcli device set wlan0 managed yes >/dev/null 2>&1 || true
        ip addr flush dev wlan0 >/dev/null 2>&1 || true # drop a leftover AP address

        if [ -f /boot/firmware/wifi-ap.env ]; then
          # Mesh mode: generate the declared network. SSID=/PASSWORD= come from
          # the file; a MISSING line falls back to the baked-in default, while
          # an explicitly empty `PASSWORD=` line means an OPEN network.
          MESH_SSID=${lib.escapeShellArg cfg.ssid}
          MESH_PSK=${lib.escapeShellArg cfg.psk}
          # shellcheck disable=SC1091
          . /boot/firmware/wifi-ap.env
          MESH_SSID=''${SSID:-$MESH_SSID}
          if grep -q '^PASSWORD=' /boot/firmware/wifi-ap.env; then
            MESH_PSK=''${PASSWORD-}
          fi

          # Host the mesh on this Pi so phones (and a directly-cabled second
          # Pi) can reach its mailbox. Ethernet doesn't change this: a cabled
          # uplink is just for administration, never a reason not to host.
          add_ap "$MESH_SSID" "$MESH_PSK"
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
      extraGroups = [
        "wheel"
        "networkmanager"
      ];
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
