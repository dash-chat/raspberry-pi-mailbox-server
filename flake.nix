{
  description = "Raspberry Pi NixOS image: Dash Chat LAN mailbox (mDNS announce/discovery + replication)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    dash-chat.url = "github:dash-chat/dash-chat/feat/local-mailbox-server";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      dash-chat,
      ...
    }:
    {
      packages.x86_64-linux = {
        default = dash-chat.packages.x86_64-linux.replicating-local-mailbox-server;
        # The flashable Raspberry Pi SD image. Built for aarch64; on an x86_64
        # builder this needs `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
      };

      packages.aarch64-linux = {
        default = dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
        # Same image, built natively on an aarch64 builder (e.g. CI's arm runner).
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
      };

      nixosConfigurations.mailbox-pi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-5
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./nix/nixos-module.nix
          ./nix/appliance.nix
          ./nix/map-lite.nix
          ./nix/rpi.nix
          ({ ... }: {
            services.dashchat-mailbox.package =
              dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
          })
        ];
      };
    };
}
