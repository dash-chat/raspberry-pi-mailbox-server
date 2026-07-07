# Captive portal for AP mode: when the Pi hosts the mesh on wlan0, devices that
# connect get the OS "sign in to network" screen showing the portal (portal/, a
# Svelte SPA) instead of a silent "no internet" network.
#
# How the pieces fit:
#   * AP mode runs its own dnsmasq (dashchat-ap-dnsmasq, see appliance.nix)
#     which reads /etc/dashchat-ap/dnsmasq.d/ — a wildcard `address=/#/` there
#     resolves EVERY name to the Pi, so the OS connectivity probes
#     (connectivitycheck.gstatic.com, captive.apple.com, msftconnecttest.com…)
#     land on our nginx. Client mode is untouched: that dnsmasq only runs when
#     the Pi hosts the AP.
#   * nginx answers every unknown Host with a 302 to the portal — a failed
#     probe is exactly what makes phones pop the captive-portal screen.
#   * An nftables/iptables REDIRECT catches clients with hardcoded DNS servers
#     (e.g. 8.8.8.8), which would otherwise time out instead of seeing the
#     portal. Harmless in client mode: nothing routes DNS through the Pi then.
#
# In AP mode the Pi has no uplink (no ethernet, wlan0 is busy hosting), so
# hijacking DNS costs clients nothing — there is no internet to break. When the
# mesh is broadcast by a cabled access point (mAP lite) instead, that AP owns
# DHCP/DNS and this module stays inert.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashchat.captivePortal;
  apAddress = config.dashchat.wifi.apAddress;
in
{
  options.dashchat.captivePortal = {
    enable = lib.mkEnableOption "captive portal for AP (mesh-hosting) mode" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./portal.nix { };
      description = "Built portal SPA (static files for nginx to serve).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Resolve every DNS name to the Pi for AP clients.
    environment.etc."dashchat-ap/dnsmasq.d/captive-portal.conf".text = ''
      address=/#/${apAddress}
    '';

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;

      virtualHosts = {
        # The portal itself, on the AP's pinned address (and the mDNS hostname,
        # for browsing to it from client/ethernet setups).
        captive-portal = {
          serverName = apAddress;
          serverAliases = [ "${config.networking.hostName}.local" ];
          root = cfg.package;
          locations."/" = {
            tryFiles = "$uri $uri/ /index.html";
          };
          # Same-origin bridge to the mailbox API, so the portal can show
          # mailbox status without CORS (captive webviews are picky).
          locations."/api/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.dashchat-mailbox.httpPort}/";
          };
        };

        # Everything else — i.e. the OS connectivity probes, which wildcard DNS
        # steers here — redirects to the portal. The non-expected answer is
        # what triggers the "sign in to network" screen.
        captive-catchall = {
          default = true;
          serverName = "_";
          locations."/".return = "302 http://${apAddress}/";
        };
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ 80 ];

      # Clients that ignore our DHCP-provided DNS still hit the portal: rewrite
      # any DNS/HTTP leaving through wlan0 to the Pi itself. Own chain so
      # firewall reloads stay idempotent.
      extraCommands = ''
        iptables -t nat -N captive-portal 2>/dev/null || true
        iptables -t nat -F captive-portal
        iptables -t nat -A captive-portal -p udp --dport 53 -j REDIRECT --to-ports 53
        iptables -t nat -A captive-portal -p tcp --dport 53 -j REDIRECT --to-ports 53
        iptables -t nat -A captive-portal -p tcp --dport 80 -j REDIRECT --to-ports 80
        iptables -t nat -C PREROUTING -i wlan0 -j captive-portal 2>/dev/null || \
          iptables -t nat -A PREROUTING -i wlan0 -j captive-portal
      '';
      extraStopCommands = ''
        iptables -t nat -D PREROUTING -i wlan0 -j captive-portal 2>/dev/null || true
        iptables -t nat -F captive-portal 2>/dev/null || true
        iptables -t nat -X captive-portal 2>/dev/null || true
      '';
    };
  };
}
