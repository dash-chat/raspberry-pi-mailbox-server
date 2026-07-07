# Appliance basics: hostname, Wi-Fi provisioning, headless SSH.
#
# Wi-Fi has two modes, chosen at boot by whether /boot/firmware/wifi-ap.env
# exists:
#   * present -> "mesh mode": this Pi hosts the declared network
#     (SSID=/PASSWORD=, falling back to the baked-in defaults below) on wlan0
#     (AP mode, via hostapd — deliberately range-limited to minimum tx power /
#     rate floor / RSSI gate, see the options). Ethernet is just an extra
#     network interface (e.g. for administering the Pi while the AP runs).
#   * absent -> "client mode": just join the network named in
#     /boot/firmware/wifi.env (SSID=/PASSWORD=) like a normal Wi-Fi device.
{ config, lib, pkgs, ... }:
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
        `/boot/firmware/wifi-ap.env` leaves `PASSWORD=` unset.
      '';
    };
    country = lib.mkOption {
      type = lib.types.str;
      default = "ES";
      description = "Wi-Fi regulatory country code.";
    };
    apTxPowerDbm = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        Transmit power in dBm for wlan0 while the Pi hosts the mesh (AP mode).
        Defaults to the minimum the Pi's brcmfmac driver accepts, keeping the
        network's radio footprint (and usable distance) as small as possible —
        raise it if clients need to connect from further away.
      '';
    };
    apRssiThresholdDbm = lib.mkOption {
      type = lib.types.int;
      default = -40;
      description = ''
        Minimum client signal strength (dBm, as received by the Pi) to answer
        probes or accept association in AP mode. NOTE: on the Pi's brcmfmac
        this fails open — the driver reports no signal strength on management
        frames (verified live), so hostapd's RSSI gate never rejects anyone.
        Kept for hardware/kernels that do report it. Actual range limiting is
        done by minimum tx power plus dashchat-ap-guard's link-quality
        eviction (see apEvictBelowMbit).
      '';
    };
    apEvictBelowMbit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = ''
        Evict an AP-mode client whose AP->client bitrate sits below this
        (Mbit/s) for two consecutive 3 s polls. The firmware's rate control is
        the distance proxy on this hardware (brcmfmac reports no per-station
        RSSI): walk-test data at 1 dBm tx power showed clients beside the Pi
        at 52-72 Mbit/s (never below 39, even mid-walk) and clients ~20 m away
        at 7-22 Mbit/s, so 24 splits the two regimes cleanly.
      '';
    };
    apAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.1";
      description = ''
        IPv4 address the Pi takes on wlan0 when hosting the mesh (AP mode).
        Pinned (rather than NetworkManager's shared-mode default) so the
        captive portal's nginx/DNS config can reference it deterministically.
      '';
    };
  };

  config = {
    networking.hostName = lib.mkDefault "dashchat-mailbox";

    # Stamp the image so `cat /etc/dashchat-version` over SSH settles which
    # build a card actually carries (we've debugged a stale reflash before).
    # Bump when changing Wi-Fi behavior.
    environment.etc."dashchat-version".text = "2026-07-07b guard v2: probe pings, evict below ${toString cfg.apEvictBelowMbit} Mbit/s\n";

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

    # --- AP mode: hostapd, not NetworkManager ----------------------------------
    # NM's AP mode can't express the range-limiting knobs we want (data-rate
    # floor, RSSI association gate), so when this Pi hosts the mesh itself,
    # wifi-provision writes /run/dashchat-ap/hostapd.conf, marks wlan0 as
    # unmanaged and starts these two services. Client modes still go through NM.
    systemd.services.dashchat-hostapd = {
      description = "hostapd for the Pi-hosted mesh AP (range-limited)";
      # No wantedBy: started (and stopped) only by wifi-provision, so a card
      # that switches roles between boots never races a stale AP.
      wants = [ "dashchat-ap-guard.service" ];
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "dashchat-ap-addr" ''
          ${pkgs.iproute2}/bin/ip addr replace ${cfg.apAddress}/24 dev wlan0
        '';
        ExecStart = "${pkgs.hostapd}/bin/hostapd /run/dashchat-ap/hostapd.conf";
        # Clamp radio power once the AP is up. Retries because hostapd is still
        # bringing the interface up when ExecStartPost fires; brcmfmac may
        # round or clamp the requested value.
        ExecStartPost = pkgs.writeShellScript "dashchat-ap-txpower" ''
          for _ in $(seq 10); do
            ${pkgs.iw}/bin/iw dev wlan0 set txpower fixed ${toString (cfg.apTxPowerDbm * 100)} && exit 0
            sleep 1
          done
          echo "could not clamp wlan0 txpower" >&2
        '';
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # "You must be standing beside the Pi": watches associated stations and
    # deauths any whose link says they walked away. RSSI would be the natural
    # metric, but brcmfmac reports NO per-station signal in AP mode (verified
    # live: `iw station dump` has no "signal:" lines), so this reads the
    # AP->client data path instead: at 1 dBm tx power the firmware's rate
    # control collapses sharply with distance (52-72 Mbit/s beside the Pi,
    # 7-22 Mbit/s at ~20 m in walk tests), making bitrate a reliable proxy.
    systemd.services.dashchat-ap-guard = {
      description = "Evict mesh-AP clients that move away from the Pi";
      bindsTo = [ "dashchat-hostapd.service" ];
      after = [ "dashchat-hostapd.service" ];
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "dashchat-ap-guard" ''
          # Each poll pings every station (via its wlan0 neighbor-table IP) so
          # tx bitrate / tx failed stay fresh even for idle stations -- without
          # this, a far idle phone keeps its last "good" bitrate forever and is
          # never evicted. A station is "bad" on a poll when either:
          #   * its tx bitrate sits below the eviction floor (= far, see the
          #     apEvictBelowMbit option for the calibration data); or
          #   * most probe frames since the last poll went unacked (tx failed
          #     delta outpacing tx packets delta, min 6 attempts).
          # Two consecutive bad polls at 3 s -> deauth + a $ban-second deny-ACL
          # ban. The ban matters: hostapd's RSSI join gate fails open on this
          # driver, so without it the phone would rejoin from afar within
          # seconds and flap forever. If it's still far when the ban lifts,
          # it's re-banned one strike cycle after rejoining.
          ban=30
          min_rate=${toString cfg.apEvictBelowMbit}
          declare -A strikes banned_at prev_ok prev_fail
          while sleep 3; do
            for m in "''${!banned_at[@]}"; do # lift expired bans
              if [ $(( SECONDS - ''${banned_at[$m]} )) -ge "$ban" ]; then
                ${pkgs.hostapd}/bin/hostapd_cli -p /run/dashchat-ap deny_acl DEL_MAC "$m" >/dev/null || true
                unset "banned_at[$m]"
              fi
            done
            # Probe every station so the counters below are fresh this poll.
            while read -r sta_ip; do
              ${pkgs.iputils}/bin/ping -c 3 -W 0.4 -i 0.15 -I wlan0 "$sta_ip" >/dev/null 2>&1 &
            done < <(${pkgs.iproute2}/bin/ip -4 neigh show dev wlan0 \
              | ${pkgs.gawk}/bin/awk '$2 == "lladdr" {print $1}')
            wait
            present=" "
            while read -r mac txbr ok fail; do
              present="$present$mac "
              d_ok=$(( ok - ''${prev_ok[$mac]:-$ok} ))
              d_fail=$(( fail - ''${prev_fail[$mac]:-$fail} ))
              prev_ok[$mac]=$ok
              prev_fail[$mac]=$fail
              bad=0
              [ "''${txbr%%.*}" -lt "$min_rate" ] && bad=1
              if [ "$d_ok" -ge 0 ] && [ "$d_fail" -ge 0 ]; then # negative = counters reset on reassoc
                attempts=$(( d_ok + d_fail ))
                if [ "$attempts" -ge 6 ] && [ $(( d_fail * 2 )) -gt "$attempts" ]; then
                  bad=1
                fi
              fi
              if [ "$bad" = 1 ]; then
                strikes[$mac]=$(( ''${strikes[$mac]:-0} + 1 ))
                if [ "''${strikes[$mac]}" -ge 2 ]; then
                  echo "deauth+ban $mac: tx bitrate $txbr MBit/s, delta acked $d_ok / failed $d_fail"
                  ${pkgs.hostapd}/bin/hostapd_cli -p /run/dashchat-ap deny_acl ADD_MAC "$mac" >/dev/null || true
                  banned_at[$mac]=$SECONDS
                  ${pkgs.hostapd}/bin/hostapd_cli -p /run/dashchat-ap deauthenticate "$mac" >/dev/null || true
                  strikes[$mac]=0
                fi
              else
                strikes[$mac]=0
              fi
            done < <(${pkgs.iw}/bin/iw dev wlan0 station dump \
              | ${pkgs.gawk}/bin/awk '
                  function flush() { if (mac != "" && br != "" && ok != "" && fail != "") print mac, br, ok, fail }
                  $1 == "Station" { flush(); mac = $2; br = ok = fail = "" }
                  $1 == "tx" && $2 == "packets:" { ok = $3 }
                  $1 == "tx" && $2 == "failed:"  { fail = $3 }
                  $1 == "tx" && $2 == "bitrate:" { br = $3 }
                  END { flush() }')
            for m in "''${!strikes[@]}"; do # forget stations that left
              case "$present" in *" $m "*) ;; *) unset "strikes[$m]" "prev_ok[$m]" "prev_fail[$m]" ;; esac
            done
          done
        '';
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # DHCP + DNS for AP clients (NM's shared mode provided these; hostapd does
    # not). The captive portal drops its wildcard-DNS file into dnsmasq.d.
    environment.etc."dashchat-ap/dnsmasq.conf".text = ''
      port=53
      interface=wlan0
      bind-dynamic
      no-resolv
      dhcp-range=${apPrefix}.10,${apPrefix}.250,12h
      dhcp-option=option:router,${cfg.apAddress}
      dhcp-option=option:dns-server,${cfg.apAddress}
      dhcp-authoritative
      conf-dir=/etc/dashchat-ap/dnsmasq.d/,*.conf
    '';
    # Keep the conf-dir present even with the captive portal disabled, so
    # dnsmasq doesn't fail on a missing directory.
    environment.etc."dashchat-ap/dnsmasq.d/.keep".text = "";

    systemd.services.dashchat-ap-dnsmasq = {
      description = "DHCP/DNS for the Pi-hosted mesh AP";
      after = [ "dashchat-hostapd.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/etc/dashchat-ap/dnsmasq.conf";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    networking.firewall.interfaces.wlan0 = {
      allowedUDPPorts = [ 53 67 ]; # AP-mode DNS + DHCP
      allowedTCPPorts = [ 53 ];
    };

    systemd.services.wifi-provision = {
      description = "Provision Wi-Fi: mesh mode (wifi-ap.env) hosts the mesh AP, else client mode joins wifi.env";
      after = [ "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.networkmanager pkgs.iw pkgs.coreutils pkgs.iproute2 pkgs.systemd ];
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
        wpa=2
        wpa_key_mgmt=WPA-PSK
        rsn_pairwise=CCMP

        # 2.4 GHz so that cheap/old 2.4-only devices can still join; minimum
        # tx power and the ap-guard do the range limiting.
        country_code=${cfg.country}
        ieee80211d=1
        hw_mode=g
        channel=1
        wmm_enabled=1

        # 802.11h power constraint: compliant clients transmit 20 dB below the
        # regulatory max, shrinking the client->AP side of the cell too.
        local_pwr_constraint=20

        # Rate floor (units of 100 kbit/s), best effort ONLY: the brcmfmac
        # firmware (full-MAC) was observed ignoring both this and the absence
        # of ieee80211n -- beacons still advertised HT and stations linked at
        # 65-72 Mbit/s MCS rates. Kept for drivers that honor it; on this
        # hardware the ap-guard is the real range enforcement.
        supported_rates=540
        basic_rates=540

        # Distance gate: ignore probes / reject association from clients the Pi
        # hears weaker than this. KNOWN to fail open on the Pi's brcmfmac
        # (it doesn't report signal strength on management frames); kept in
        # case a future kernel/firmware starts reporting it.
        rssi_ignore_probe_request=${toString cfg.apRssiThresholdDbm}
        rssi_reject_assoc_rssi=${toString cfg.apRssiThresholdDbm}

        # The RSSI gate only applies at join time -- these evict clients that
        # associated up close and then walked away: kick on repeated unacked
        # frames, and poll/expire idle stations after a minute.
        disassoc_low_ack=1
        ap_max_inactivity=60
        EOF
          printf 'ssid=%s\nwpa_passphrase=%s\n' "$ssid" "$psk" >> /run/dashchat-ap/hostapd.conf
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
          # the file; anything left unset falls back to the baked-in defaults.
          MESH_SSID=${lib.escapeShellArg cfg.ssid}
          MESH_PSK=${lib.escapeShellArg cfg.psk}
          # shellcheck disable=SC1091
          . /boot/firmware/wifi-ap.env
          MESH_SSID=''${SSID:-$MESH_SSID}
          MESH_PSK=''${PASSWORD:-$MESH_PSK}

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
