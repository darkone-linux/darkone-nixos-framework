# fleet-update — updates and deploys a DNF fleet in waves (Bun, OpenTUI).
#
# Installed on deployment hosts by `darkone.admin.fleet-update`, launched by
# `just fleet-update`. Behaviour is specified in the consumer workspace
# (`.specs/dnf/outils-de-deploiement-du-parc.md`).
#
# :::note[Sources run by `bun run`]
# No `bun build --compile`: the bundle breaks files read through
# `import.meta.url` (`mock/scenarios/`). Same launch as co-development, so
# both modes behave alike.
# :::
#
# :::note[Pinning]
# A release tag, pinned by the release train (`just release`, codev) or by
# `just pkg-update fleet-update [version]`. Before the first release: a `main`
# commit (`rev`, `--version=branch`), which the train turns into the tag form.
# :::

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  makeBinaryWrapper,
  writableTmpDirAsHomeHook,
  nix-update-script,
  git,
  nix-eval-jobs,
  openssh,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "fleet-update";
  version = "0-unstable-2026-09-16";

  src = fetchFromGitHub {
    owner = "darkone-linux";
    repo = "dnf-fleet-update";
    rev = "de1bd5007c96d0cc0c18fbeedc4c40859173d59e";
    hash = "sha256-3JENJlDS+V6ytfIkZMCzr31JBgItuyAAoEEwAvKNcsI=";
  };

  # Fixed-output: `bun install` needs the network. `--os`/`--cpu` wildcards
  # fetch every OpenTUI native library, so one hash serves all platforms.
  node_modules = stdenvNoCC.mkDerivation {
    pname = "${finalAttrs.pname}-node_modules";
    inherit (finalAttrs) version src;

    impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
      "GIT_PROXY_COMMAND"
      "SOCKS_SERVER"
    ];

    nativeBuildInputs = [
      bun
      writableTmpDirAsHomeHook
    ];

    dontConfigure = true;

    # `--production`: biome, tsc and type packages are development-only.
    buildPhase = ''
      runHook preBuild

      export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
      bun install \
        --cpu="*" \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress \
        --os="*" \
        --production

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R node_modules $out/

      runHook postInstall
    '';

    # A fixed-output derivation must not reference store paths (patched shebangs).
    dontFixup = true;

    outputHash = "sha256-HXuXGr1duuH1dYueBdaqxE+aDHr9XYSHngVQyimmQgU=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  };

  nativeBuildInputs = [ makeBinaryWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # `tsconfig.json` carries the JSX runtime (`@opentui/react`) bun needs to
  # load `.tsx` sources.
  #
  # `--suffix`, not `--prefix`: host tools win. A store `ping` or `nix` would
  # shadow the capability wrapper or the daemon-matched client.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/fleet-update
    cp -R package.json tsconfig.json src mock $out/lib/fleet-update/
    cp -R ${finalAttrs.node_modules}/node_modules $out/lib/fleet-update/

    makeWrapper ${lib.getExe bun} $out/bin/fleet-update \
      --add-flags "run $out/lib/fleet-update/src/main.tsx" \
      --suffix PATH : ${
        lib.makeBinPath [
          git
          nix-eval-jobs
          openssh
        ]
      }

    runHook postInstall
  '';

  # No `versionCheckHook` until the entry point implements `--version`.

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--version=branch"
      "--subpackage"
      "node_modules"
    ];
  };

  meta = {
    description = "Update and deploy a Darkone NixOS Framework fleet in waves";
    homepage = "https://github.com/darkone-linux/dnf-fleet-update";
    license = lib.licenses.gpl3Plus;
    mainProgram = "fleet-update";

    # OpenTUI ships its native core prebuilt, fetched with `node_modules`.
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode
    ];
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];

    # Filled in when the package is submitted to nixpkgs (cf. `pr-nixpkgs`).
    maintainers = [ ];
  };
})
