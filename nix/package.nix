# Crane build of the `local-mailbox-server` binary from the dash-chat source
# tree (the `replicating-local-mailbox-server` crate's bin target). Called with
# a toolchain-aware `craneLib` and the cleaned dash-chat `src`.
{ craneLib
, lib
, openssl
, pkg-config
, src
}:
let
  commonArgs = {
    inherit src;
    strictDeps = true;
    pname = "local-mailbox-server";
    version = "0.1.0";

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ openssl ];

    # Tests need a real LAN / network; skip them in the sandbox.
    doCheck = false;

    cargoExtraArgs = "-p replicating-local-mailbox-server";
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;
  meta = {
    description = "Dash Chat LAN mailbox daemon (server + mDNS discovery + replication)";
    mainProgram = "local-mailbox-server";
    license = lib.licenses.agpl3Only;
  };
})
