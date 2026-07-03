{
  description = "Raspberry Pi NixOS image: Dash Chat LAN mailbox (mDNS announce/discovery + replication)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # The Rust lives in a dash-chat branch: the `local-mailbox-server` binary is
    # the `replicating-local-mailbox-server` crate's bin target. Consumed as a
    # plain source tree (not a flake) so we crane-build it here. Repoint to a
    # fork/upstream URL when the branch moves.
    dash-chat = {
      url = "github:dash-chat/dash-chat/feat/local-mailbox-server";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      rust-overlay,
      nixos-hardware,
      dash-chat,
      ...
    }:
    let
      hostSystem = "x86_64-linux";

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
          config.allowUnfree = true; # Raspberry Pi firmware
        };

      # Build the `local-mailbox-server` binary for an arbitrary pkgs (native on
      # the host, or emulated aarch64 for the image), using dash-chat's pinned
      # toolchain and source.
      mailboxFor =
        pkgs:
        let
          rust = pkgs.rust-bin.fromRustupToolchainFile "${dash-chat}/rust-toolchain.toml";
          craneLib = (crane.mkLib pkgs).overrideToolchain rust;
        in
        pkgs.callPackage ./nix/package.nix {
          inherit craneLib;
          src = craneLib.cleanCargoSource dash-chat;
        };
    in
    {
      packages.${hostSystem} = {
        default = mailboxFor (pkgsFor hostSystem);
        # The flashable Raspberry Pi SD image. Built for aarch64; on an x86_64
        # builder this needs `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
      };

      packages.aarch64-linux.default = mailboxFor (pkgsFor "aarch64-linux");

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
            services.dashchat-mailbox.package = mailboxFor (pkgsFor "aarch64-linux");
          })
        ];
      };
    };
}
