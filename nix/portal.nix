# The captive-portal web app (portal/): a Vite + Svelte (TypeScript) SPA,
# packaged as its static dist/ output for nginx to serve.
{
  stdenv,
  lib,
  nodejs,
  pnpm,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "dashchat-captive-portal";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../portal;
    # Don't let a local node_modules/ or dist/ leak into the build's src hash.
    filter =
      path: _type:
      let
        base = baseNameOf path;
      in
      base != "node_modules" && base != "dist";
  };

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
  ];

  # Regenerate after changing portal/pnpm-lock.yaml: set to lib.fakeHash,
  # rebuild, and copy the hash from the mismatch error.
  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 2;
    hash = "sha256-j5xTJZmyXfJ/RKFvCaGWRSW865Fpzxv3hT45WD4adpg=";
  };

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  # `vite build` output is plain static files; nothing to install beyond dist/.
  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
})
