# NixOS module: run local-mailbox-server as a system service, announced on the
# LAN via its own in-process mDNS responder.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dashchat-mailbox;
in
{
  options.services.dashchat-mailbox = {
    enable = lib.mkEnableOption "Dash Chat LAN mailbox server" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "The local-mailbox-server package to run.";
    };

    addr = lib.mkOption {
      type = lib.types.str;
      default = "[::]:3000";
      description = "Address the HTTP mailbox API binds to (dual-stack by default).";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "HTTP port to open in the firewall (must match `addr`).";
    };

    serviceType = lib.mkOption {
      type = lib.types.str;
      default = "_dashchat._tcp.local.";
      description = "mDNS service type to announce/browse. Must match the Dash Chat app.";
    };

    cloud = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Also replicate with the production cloud mailbox (the same URL the
          Dash Chat app uses), bridging the LAN to the internet. Requires the Pi
          to have an internet uplink. Set false for a purely-local deployment.
        '';
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://0-19.mailbox.staging.darksoil.studio";
        description = "Cloud/remote mailbox URL to bridge with when `cloud.enable` is set.";
      };
    };

    syncInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Seconds between replication passes.";
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "wlan0"
        "end0"
        "eth0"
      ];
      description = ''
        Interfaces treated as trusted LAN. iroh blob transfer uses QUIC over UDP
        on a dynamic port, so peers need unrestricted UDP to fetch blobs; trusting
        the LAN interface is the simplest way to allow that on a home network.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.dashchat-mailbox = {
      description = "Dash Chat LAN mailbox (server + mDNS + replication)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe cfg.package)
            "--db-path /var/lib/dashchat-mailbox/mailbox.redb"
            "--addr ${lib.escapeShellArg cfg.addr}"
            "--service-type ${lib.escapeShellArg cfg.serviceType}"
            "--sync-interval ${toString cfg.syncInterval}"
          ]
          ++ lib.optional cfg.cloud.enable "--cloud-url ${lib.escapeShellArg cfg.cloud.url}"
        );

        # Persistent state → stable server identity (MailboxId) across reboots.
        StateDirectory = "dashchat-mailbox";
        Restart = "always";
        RestartSec = 5;
        DynamicUser = true;

        # Hardening (StateDirectory stays writable under these).
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };

      environment.RUST_LOG = lib.mkDefault "local_mailbox_server=info,replicating_local_mailbox_server=info,mailbox_local_server=info,mailbox_client=info,mailbox_mdns_discovery=info,mailbox_server=warn";
    };

    # Our binary runs its own mDNS responder (mdns-sd); Avahi would contend for
    # UDP 5353, so keep it off unless something else explicitly enables it.
    services.avahi.enable = lib.mkDefault false;

    networking.firewall = {
      allowedTCPPorts = [ cfg.httpPort ];
      allowedUDPPorts = [ 5353 ]; # mDNS
      trustedInterfaces = cfg.trustedInterfaces;
    };
  };
}
