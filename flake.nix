{
  description = "Raspberry Pi NixOS image: Dash Chat LAN mailbox (mDNS announce/discovery + replication)";

  nixConfig = {
    extra-substituters = [
      "https://dash-chat.cachix.org"
      # Prebuilt vendor kernel/firmware/packages, so CI doesn't compile the
      # Raspberry Pi kernel from source on every build.
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "dash-chat.cachix.org-1:oAsoaEZ7e4UJlveRXF45MJ1P+Tf3OKFN5QkB8BuPaiM="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    # nixos-raspberrypi owns the Pi 5 boot path: vendor kernel (linux-rpi) with
    # matched firmware/DTBs, declarative config.txt, and the generational
    # bootloader. It pins its own nixpkgs, which the system is built against.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    dash-chat.url = "github:dash-chat/dash-chat/replicating-local-mailbox-server";

    # Reuse the nixpkgs nixos-raspberrypi already pins (no extra download); used
    # only for the devShell tooling.
    nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
  };

  outputs =
    {
      self,
      nixos-raspberrypi,
      dash-chat,
      nixpkgs,
      ...
    }:
    {
      # Dev tooling (e.g. `just` for the flashing recipes). Enter with
      # `nix develop`.
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = with nixpkgs.legacyPackages.x86_64-linux; [
          just # flashing recipes
          zstd # decompress the built .img.zst
          nodejs # captive-portal (portal/) development
          pnpm # portal package manager
        ];
      };

      packages.x86_64-linux = {
        default = dash-chat.packages.x86_64-linux.replicating-local-mailbox-server;
        # The flashable Raspberry Pi SD image. Built for aarch64; on an x86_64
        # builder this needs `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
        # The captive-portal SPA (portal/), buildable standalone for iteration.
        portal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./nix/portal.nix { };
      };

      packages.aarch64-linux = {
        default = dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
        # Same image, built natively on an aarch64 builder (e.g. CI's arm runner).
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
        portal = nixpkgs.legacyPackages.aarch64-linux.callPackage ./nix/portal.nix { };
      };

      # `nixos-raspberrypi.lib.nixosSystem` is a drop-in for
      # `nixpkgs.lib.nixosSystem`: it pins `nixpkgs.hostPlatform = aarch64-linux`,
      # injects the vendor kernel/firmware overlays, trusts the binary cache, and
      # passes `nixos-raspberrypi` to the modules via specialArgs.
      nixosConfigurations.mailbox-pi = nixos-raspberrypi.lib.nixosSystem {
        modules = [
          {
            imports = with nixos-raspberrypi.nixosModules; [
              # Pi 5 board support: vendor kernel + matched firmware/DTBs, and
              # the config.txt / generational bootloader plumbing.
              raspberry-pi-5.base
              # Fixes/optimisations for the default rpi5 kernel's 16k page size.
              raspberry-pi-5.page-size-16k
              # Builds `config.system.build.sdImage`; also disables nixpkgs'
              # all-hardware profile (whose stray initrd modules break the
              # vendor kernel) and selects the generational bootloader for RPi5.
              sd-image
            ];
          }
          ./nix/nixos-module.nix
          ./nix/appliance.nix
          ./nix/captive-portal.nix
          ./nix/rpi.nix
          ({ ... }: {
            services.dashchat-mailbox.package =
              dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
          })
        ];
      };
    };
}
