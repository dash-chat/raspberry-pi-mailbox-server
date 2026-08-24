# NixOS module: run mailbox-local-server as a system service. The server
# announces itself over mDNS in-process so Dash Chat peers on the LAN can
# discover and sync against it.
{
  config,
  lib,
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
      description = "The mailbox-local-server package to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.dashchat-mailbox = {
      description = "Dash Chat LAN mailbox (server + mDNS)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe' cfg.package "mailbox-local-server")
          "--db-path /var/lib/dashchat-mailbox/mailbox.redb"
          "--addr [::]:3000"
        ];

        # Persistent state → stable server identity (MailboxId) across reboots.
        StateDirectory = "dashchat-mailbox";
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
      };

      environment.RUST_LOG = lib.mkDefault "mailbox_local_server=info";
    };

    # Our binary runs its own mDNS responder (mdns-sd); Avahi would contend for
    # UDP 5353, so keep it off unless something else explicitly enables it.
    services.avahi.enable = lib.mkDefault false;

    networking.firewall = {
      allowedTCPPorts = [ 3000 ];
      allowedUDPPorts = [ 5353 ]; # mDNS
      # iroh blob transfer uses QUIC over UDP on a dynamic port, so peers need
      # unrestricted UDP to fetch blobs; trusting the LAN interfaces is the
      # simplest way to allow that.
      trustedInterfaces = [
        "end0"
        "eth0"
      ];
    };
  };
}
