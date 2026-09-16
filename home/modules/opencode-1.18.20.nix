# Pin for a known-good opencode release.
#
# nixpkgs 1.18.30 crashes on every prompt with
# `TypeError: undefined is not an object (evaluating 'a.name')` inside
# `SystemPrompt.environment`, regardless of model or config — a confirmed
# upstream regression, reproducible even on a clean $HOME:
#   https://github.com/anomalyco/opencode/issues/48803
#   https://github.com/anomalyco/opencode/issues/48965
#   https://github.com/anomalyco/opencode/issues/48996
#
# This is nixpkgs' own opencode package.nix (pkgs/by-name/op/opencode),
# with `version`, the source hash, and the `node_modules` fixed-output
# derivation hash pinned back to v1.18.20 — the last version reported
# working. Drop this file and switch back to plain `pkgs.opencode` once
# nixpkgs ships a fixed release past 1.18.30.
{
  lib,
  stdenv,
  bun,
  darwin,
  fetchFromGitHub,
  makeWrapper,
  models-dev,
  nodejs,
  nix-update-script,
  ripgrep,
  sysctl,
  installShellFiles,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
let
  node_modules =
    finalAttrs:
    stdenv.mkDerivation {
      pname = "${finalAttrs.pname}-node_modules";
      inherit (finalAttrs) version src;

      __structuredAttrs = true;
      strictDeps = true;

      impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
        "GIT_PROXY_COMMAND"
        "SOCKS_SERVER"
      ];

      nativeBuildInputs = [
        bun
        writableTmpDirAsHomeHook
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
        bun install \
          --cpu="*" \
          --frozen-lockfile \
          --filter ./ \
          --filter ./packages/app \
          --filter ./packages/desktop \
          --filter ./packages/opencode \
          --filter ./packages/shared \
          --ignore-scripts \
          --no-progress \
          --os="*"

        bun --bun ./nix/scripts/canonicalize-node-modules.ts
        bun --bun ./nix/scripts/normalize-bun-binaries.ts

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        find . -type d -name node_modules -exec cp -R --parents {} $out \;

        find $out -type f -name '*.exe' -delete

        runHook postInstall
      '';

      dontFixup = true;

      outputHash = "sha256-ynllZ732mBJaeMWGa6ej8dSR+jJBoUcr/mprJAG+xd4=";
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
    };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "opencode";
  version = "1.18.20";

  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Ehj3HmTisDa2EZ4SpQZz73Ad6mfveK7l3t8kz6TXRCo=";
  };

  postPatch = ''
    substituteInPlace packages/script/src/index.ts \
      --replace-fail \
      'throw new Error(`This script requires bun@''${expectedBunVersionRange}' \
      'console.warn(`Warning: This script requires bun@''${expectedBunVersionRange}'
  ''
  + ''
    substituteInPlace packages/opencode/script/build.ts \
      --replace-fail \
      'if (item.os === process.platform && item.arch === process.arch && !item.abi)' \
      'if (false)'
  '';

  nativeBuildInputs = [
    bun
    nodejs
    installShellFiles
    makeWrapper
    writableTmpDirAsHomeHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.sigtool ];

  configurePhase = ''
    runHook preConfigure

    cp -R ${finalAttrs.passthru.node_modules}/. .
    patchShebangs node_modules
    patchShebangs packages/*/node_modules

    runHook postConfigure
  '';

  env.MODELS_DEV_API_JSON = "${models-dev}/dist/_api.json";
  env.OPENCODE_DISABLE_MODELS_FETCH = true;
  env.OPENCODE_VERSION = finalAttrs.version;
  env.OPENCODE_CHANNEL = "prod";

  buildPhase = ''
    runHook preBuild

    cd ./packages/opencode
    bun --bun ./script/build.ts --single --skip-install
    bun --bun ./script/schema.ts config.json tui.json
    substituteInPlace config.json \
      --replace-fail "https://models.dev/model-schema.json" \
                     "file://$out/share/model-schema.json"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 dist/opencode-*/bin/opencode $out/bin/opencode
    wrapProgram $out/bin/opencode \
     --prefix PATH : ${
       lib.makeBinPath (
         [
           ripgrep
         ]
         ++ lib.optionals stdenv.hostPlatform.isDarwin [
           sysctl
         ]
       )
     } \
    --set OPENCODE_DISABLE_AUTOUPDATE true \
    --run '
      data_home="''${XDG_DATA_HOME:-$HOME/.local/share}"
      legacy="$data_home/opencode/opencode-stable.db"
      canonical="$data_home/opencode/opencode.db"

      if [ -z "''${OPENCODE_DB:-}" ] \
        && [ -z "''${NIXPKGS_OPENCODE_DISABLE_LEGACY_DB_WORKAROUND:-}" ] \
        && [ -e "$legacy" ] \
        && [ ! -e "$canonical" ]; then
        export OPENCODE_DB="opencode-stable.db"

        if [ -t 2 ]; then
          echo "Detected legacy nixpkgs OpenCode database at $legacy." >&2
          echo "Continuing to use it for compatibility." >&2
          echo "See https://github.com/NixOS/nixpkgs/pull/558549 for migration instructions." >&2
          echo "Set NIXPKGS_OPENCODE_DISABLE_LEGACY_DB_WORKAROUND=1 to disable this workaround." >&2
        fi
      fi
    '

    install -Dm644 ${models-dev.jsonschema} $out/share/model-schema.json
    install -Dm644 config.json $out/share/config.json
    install -Dm644 tui.json $out/share/tui.json
    install -Dm644 ../web/public/theme.json $out/share/theme.json

    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenv.hostPlatform.isDarwin ''
      codesign --force --sign - $out/bin/.opencode-wrapped
    ''
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      installShellCompletion --cmd opencode \
        --bash <($out/bin/opencode completion) \
        --zsh <(SHELL=/bin/zsh $out/bin/opencode completion)
    '';

  dontStrip = true;

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [
    "HOME"
    "OPENCODE_DISABLE_MODELS_FETCH"
  ];
  versionCheckProgramArg = "--version";

  passthru = {
    jsonschema = {
      config = "${finalAttrs.finalPackage}/share/config.json";
      theme = "${finalAttrs.finalPackage}/share/theme.json";
      tui = "${finalAttrs.finalPackage}/share/tui.json";
    };
    node_modules = node_modules finalAttrs;
    updateScript = nix-update-script {
      extraArgs = [
        "--subpackage"
        "node_modules"
      ];
    };
  };

  meta = {
    description = "AI coding agent built for the terminal (pinned to 1.18.20, see header comment)";
    homepage = "https://github.com/anomalyco/opencode";
    changelog = "https://github.com/anomalyco/opencode/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
    ];
    mainProgram = "opencode";
  };
})
