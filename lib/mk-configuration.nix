# DNF — main configuration assembler.
#
# Entry point used by consumer flakes (boilerplate, arthur-network) to build
# their `nixosConfigurations` and Colmena hive from a `workDir` containing
# `var/generated/{hosts,users,network}.nix` and `usr/`.
#
# :::tip
# Called once per consumer flake; closes over the framework inputs declared
# in `dnf/flake.nix`. The consumer only has to forward `workDir`.
# :::

{ inputs }:
workDir:

let
  inherit (inputs)
    nixpkgs
    nixpkgs-stable
    nixpkgs-geneweb
    nixpkgs-oxicloud
    nixpkgs-opencode
    home-manager
    colmena
    sops-nix
    disko
    nixos-raspberrypi
    talon-nix
    ;

  # home-manager state version of every home. Hosts freeze theirs in
  # `usr/machines/<host>/install/state.nix` (`just install`).
  unstableStateVersion = "26.05";

  # What `modules/system/dnf-release.nix` stamps on every host. `rev` is absent
  # on a dirty co-dev tree, where `dirtyShortRev` carries the `-dirty` suffix.
  dnfVersion = {
    release = nixpkgs.lib.fileContents ../VERSION;
    rev = inputs.self.shortRev or inputs.self.dirtyShortRev or "unknown";
  };

  supportedSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

  # Pure helpers; needed before dnfLibFor (arch-independent)
  hiveLib = import ./hive.nix { inherit (nixpkgs) lib; };
  inherit (hiveLib)
    getHostArch
    getHostBoard
    mkNodeArgs
    rpiBoards
    rpiBoardModules
    ;

  # Path-resolution helpers (unit-tested in `tests/unit/lib/paths_test.nix`)
  pathsLib = import ./paths.nix { inherit (nixpkgs) lib; };
  resolveProfile = pathsLib.resolveProfile {
    frameworkRoot = ./..;
    inherit workDir;
  };
  resolveNixosProfile = pathsLib.resolveNixosProfile {
    frameworkRoot = ./..;
    inherit workDir;
  };

  # Temporary: `pkgs.geneweb` from nixpkgs PR #522751. Drop it together with
  # the `nixpkgs-geneweb` input (cf. flake.nix).
  genewebOverlay = import ./overlays/geneweb.nix { inherit nixpkgs-geneweb; };

  # Temporary: `__structuredAttrs = false` on `gimp`, whose build breaks
  # otherwise. Drop once upstream makes it `__structuredAttrs`-clean.
  gimpOverlay = import ./overlays/gimp.nix;

  # Temporary: logseq official AppImage, the electron-forge build is broken
  # (nixpkgs#535206). Drop once upstream fixes the source build.
  logseqOverlay = import ./overlays/logseq.nix;

  # Temporary: outline 1.10.1 `yarn-fix.patch` + hashes (nixpkgs source fetch
  # fails). Inert on other versions; drop once nixpkgs is fixed.
  outlineOverlay = import ./overlays/outline.nix;

  # `pkgs.talon` from nix-community/talon-nix, x86_64 only (absent elsewhere),
  # for UMI (multimodal input) host profiles.
  talonOverlay = import ./overlays/talon.nix { inherit talon-nix; };

  # Temporary: `pkgs.opencode`/`pkgs.opencode-desktop` pinned to 1.18.29, as
  # 1.18.30 crashes on every prompt. Drop once a fix lands in `nixos-unstable`.
  opencodeOverlay = import ./overlays/opencode.nix { inherit nixpkgs-opencode; };

  # DNF-only packages (`pkgs/`), absent from nixpkgs: permanent until each one
  # is upstreamed.
  dnfPackagesOverlay = import ../pkgs/overlay.nix;

  # `pkgs.dnf-generator` for `admin/fleet-update.nix`, x86_64 only: absent
  # elsewhere, hence `pkgs.dnf-generator or null` on the consumer side. Curried
  # on `system`: reading `final.stdenv` recurses on test-driver nodes.
  dnfGeneratorOverlay =
    system: _final: _prev:
    nixpkgs.lib.optionalAttrs (inputs.dnf-generator.packages ? ${system}) {
      dnf-generator = inputs.dnf-generator.packages.${system}.default;
    };

  # Per-system nixpkgs instances
  nixpkgsFor = forAllSystems (
    system:
    import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    }
  );

  # CLI/services only: a GUI app from stable links an older glibc than the
  # unstable Mesa in /run/opengl-driver, so `libGLX_mesa` fails to load and
  # the app aborts on "Could not initialize GLX".
  nixpkgsStableFor = forAllSystems (
    system:
    import nixpkgs-stable {
      inherit system;
      config.allowUnfree = true;
    }
  );

  # DNF runtime lib (per-system, injected into modules via specialArgs.dnfLib).
  # Memoised like its `nixpkgsFor` neighbours: it is looked up once per host,
  # and re-importing `lib/` for each of them is pure waste.
  dnfLibFor = forAllSystems (system: import ./. { inherit (nixpkgsFor.${system}) lib; });

  # Consumer-side generated inventory
  hosts = import (workDir + "/var/generated/hosts.nix");
  users = import (workDir + "/var/generated/users.nix");

  # `network` carries the topology; the optional `matrix.nix` overlay holds the
  # alert bot identity + room IDs provisioned by `just configure-alert-bot`
  # (kept out of config.yaml, which is manual-only). Merged here so framework
  # modules keep reading `network.matrix.*` transparently.
  networkBase = import (workDir + "/var/generated/network.nix");
  matrixFile = workDir + "/var/generated/matrix.nix";
  network =
    if builtins.pathExists matrixFile then
      nixpkgs.lib.recursiveUpdate networkBase (import matrixFile)
    else
      networkBase;
  dnfConfig = import ./../config;

  # Pre-resolve NixOS-side profile module paths so `modules/user/build.nix`
  # stays agnostic to the framework/consumer layout.
  userNixosProfiles = nixpkgs.lib.mapAttrs (_login: user: resolveNixosProfile user.profile) users;

  # Common args injected as specialArgs / extraSpecialArgs.
  # `workDir` lets framework modules reference consumer-side files
  # (`usr/secrets/...`, `usr/www/...`) without baking relative paths.
  # Memoised per system: the attrset is identical for every host of a given
  # architecture.
  commonNodeArgsFor = forAllSystems (system: {
    inherit
      dnfConfig
      dnfVersion
      network
      users
      userNixosProfiles
      workDir
      ;
    pkgs-stable = nixpkgsStableFor.${system};
    dnfLib = dnfLibFor.${system};

    # Required by nixos-raspberrypi board modules to locate the flake (the same
    # specialArg its `lib.nixosSystem` wrapper would inject).
    inherit nixos-raspberrypi;
  });

  mkNodeSpecialArgs = host: {
    name = host.hostname;
    value = mkNodeArgs {
      inherit host hosts network;
      extraArgs = commonNodeArgsFor.${getHostArch host};
    };
  };

  nodeSpecialArgs = builtins.listToAttrs (map mkNodeSpecialArgs hosts);

  # Single source of truth consumed by every downstream:
  # nixosConfigurations, colmena, tests and install all derive from this.
  # `forTest` drops only what the NixOS Test Driver owns itself (the nixpkgs
  # misc module and `nixpkgs.hostPlatform.system`); everything else stays
  # identical to production for fidelity.
  mkNode =
    {
      forTest ? false,
    }:
    host:
    let
      system = getHostArch host;
      machineDir = workDir + "/usr/machines/${host.hostname}";
      hasMachineDir = builtins.pathExists machineDir;
      stateFile = machineDir + "/install/state.nix";
    in
    {
      inherit system;
      specialArgs = nodeSpecialArgs.${host.hostname};
      modules = [

        # Framework-side NixOS modules
        ../modules

        # Geneweb: upstream module imported from nixpkgs PR #522751 (drop it
        # once the PR lands in `nixos-unstable`). Parsed unconditionally, but
        # inert while `services.geneweb.enable = false`.
        "${nixpkgs-geneweb}/nixos/modules/services/web-apps/geneweb.nix"

        # Overlays go through a module: `nixosSystem` rebuilds its own `pkgs`,
        # which `nixpkgsFor` never reaches. Each one is documented above.
        {
          nixpkgs.overlays = [
            dnfPackagesOverlay
            (dnfGeneratorOverlay system)
            (genewebOverlay system)
            gimpOverlay
            logseqOverlay
            outlineOverlay
            (talonOverlay system)
            (opencodeOverlay system)
          ];
        }

        # OxiCloud: upstream module imported from nixpkgs PR #516113 (drop it
        # once the PR lands in `nixos-unstable`). Parsed unconditionally, but
        # inert while `services.oxicloud.enable = false`. No overlay:
        # `pkgs.oxicloud` already comes from the main `nixpkgs` tree.
        "${nixpkgs-oxicloud}/nixos/modules/services/web-apps/oxicloud.nix"

        # Consumer-side NixOS modules overlay
        (workDir + "/usr/modules")
      ]

      # The test driver provides its own nixpkgs/system layer.
      ++ nixpkgs.lib.optionals (!forTest) [
        "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"

        # colmena imports nixpkgs without the flake version overlay ("pre-git",
        # no registry entry). Pin what `lib.nixosSystem` sets: `just apply` and
        # `fleet-update` then deploy the same toplevel.
        {
          system.nixos.versionSuffix = nixpkgs.lib.trivial.versionSuffix;
          system.nixos.revision = nixpkgs.lib.trivial.revisionWithDefault null;
          nixpkgs.flake.source = nixpkgs.outPath;
        }
      ]
      ++ [
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
        ({ config, lib, ... }: {

          # Installed hosts pin theirs in `install/state.nix`. Tests, ISO and
          # hosts not yet installed get the release: warned when a machine dir
          # exists, as a deploy would then drift at every nixpkgs bump.
          system.stateVersion = lib.mkDefault config.system.nixos.release;
          warnings = lib.optional (hasMachineDir && !builtins.pathExists stateFile) (
            "${host.hostname}: usr/machines/${host.hostname}/install/state.nix missing, "
            + "stateVersion not frozen (written by `just install`)."
          );
        })
        {
          home-manager = {

            # Reuse global pkgs from nixpkgs
            useGlobalPkgs = true;

            # Install in /etc/profiles instead of ~/.nix-profile
            useUserPackages = true;

            # Colliding files (a .zshrc, a mimeapps.list rewritten by an app)
            # move to `<file>.bkp`, overwriting an older backup rather than
            # failing the activation.
            backupFileExtension = "bkp";
            overwriteBackup = true;

            users = builtins.listToAttrs (map mkHome host.users);

            extraSpecialArgs = mkNodeArgs {
              inherit host hosts network;
              extraArgs = commonNodeArgsFor.${system} // {
                inherit inputs;
              };
            };
          };
        }
      ]

      # Raspberry Pi boards: import nixos-raspberrypi board modules (vendor
      # kernel/firmware/bootloader). Gated on `board`, not `arch`, so non-RPi
      # aarch64 hosts stay free to use their own hardware profile.
      ++ nixpkgs.lib.optionals (getHostBoard host != null) (
        rpiBoardModules nixos-raspberrypi (getHostBoard host)
      )

      # `not-detected.nix`: what `nixos-generate-config` imports. Deduplicated
      # by path when `hardware-configuration.nix` imports it too.
      ++ nixpkgs.lib.optional hasMachineDir (
        { modulesPath, ... }: { imports = [ (modulesPath + "/installer/scan/not-detected.nix") ]; }
      )

      # Host files by provenance: human, frozen at install, probed, generated.
      # Explicit list, no directory import: a stray file is never picked up.
      ++ builtins.filter builtins.pathExists [
        (machineDir + "/configuration.nix")
        (machineDir + "/install/disko.nix")
        stateFile
        (machineDir + "/hardware/hardware-configuration.nix")
        (machineDir + "/hardware/detected-hardware.nix")
        (workDir + "/var/generated/hosts/${host.hostname}.nix")
      ];
    };

  # Public API returned by mkConfigurations (see spec §9.1).
  mkNodes =
    {
      forTest ? false,
    }:
    builtins.listToAttrs (
      map (host: {
        name = host.hostname;
        value = mkNode { inherit forTest; } host;
      }) hosts
    );

  # Production variant reused by colmena + nixosConfigurations.
  prodNodes = mkNodes { forTest = false; };

  # Home-manager wiring for one user login
  mkHome = login: {
    name = login;
    value = {
      imports = [

        # Framework-side home-manager modules
        ../home

        # Consumer-side home overlay + per-user customizations
        (workDir + "/usr/home")
        (workDir + "/usr/users/${login}")

        # By path, not `import`: module errors then name the profile file.
        (resolveProfile users.${login}.profile)
      ];
      home = {
        username = login;
        homeDirectory = nixpkgs.lib.mkDefault "/home/${login}";
        stateVersion = nixpkgs.lib.mkDefault unstableStateVersion;
      };
    };
  };

  # One Colmena host descriptor, derived from the shared node definition.
  mkHost = host: {
    name = host.hostname;
    value = host.colmena // {
      nixpkgs.hostPlatform.system = prodNodes.${host.hostname}.system;
      imports = prodNodes.${host.hostname}.modules;
    };
  };

  # Per-node nixpkgs override for non-default architectures. `meta.nixpkgs` below
  # pins x86_64; aarch64 hosts need their own pkgs instance or colmena would
  # cross-build them under x86. RPi vendor packages come from the board modules'
  # overlays (cf. rpiBoardModules), so a plain aarch64 nixpkgs is enough here.
  aarch64Hosts = builtins.filter (host: getHostArch host == "aarch64-linux") hosts;
  nodeNixpkgs = builtins.listToAttrs (
    map (host: {
      name = host.hostname;
      value = nixpkgsFor.aarch64-linux;
    }) aarch64Hosts
  );

  # Colmena hive description (consumed both by `colmena` CLI and the derived
  # nixosConfigurations).
  colmenaSet = {
    meta = {
      description = "Darkone Framework Network";
      nixpkgs = nixpkgsFor.x86_64-linux;
      inherit nodeSpecialArgs nodeNixpkgs;
    };
    defaults.deployment = {
      buildOnTarget = nixpkgs.lib.mkDefault false;
      allowLocalDeployment = nixpkgs.lib.mkDefault true;
      replaceUnknownProfiles = true;
      targetUser = "nix";
    };
  }
  // builtins.listToAttrs (map mkHost hosts);

  # Standalone nixosSystem evaluations (built by nixos-rebuild / nix build).
  consumerNixosConfigurations = builtins.mapAttrs (
    _name: node:
    nixpkgs.lib.nixosSystem {
      inherit (node) system specialArgs;
      modules = node.modules;
    }
  ) prodNodes;

  # ISO images. `workDir` is forwarded so iso.nix injects the consumer's
  # `usr/secrets/nix.pub` for nixos-anywhere.
  isoNixosConfigurations = builtins.listToAttrs (
    map (system: {
      name = "iso-${system}";
      value = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit workDir;
          imgFormat = nixpkgs.lib.mkDefault "iso";
          host = {
            hostname = "new-dnf-host";
            name = "New Darkone NixOS Framework";
            profile = "minimal";
            users = [ ];
            groups = [ ];
            arch = system;
          };
        };
        modules = [
          { nixpkgs.pkgs = nixpkgsFor.${system}; }
          ../hosts/iso.nix
        ];
      };
    }) supportedSystems
  );

  # Bootable Raspberry Pi SD images (first-install media, aarch64). Built via the
  # nixos-raspberrypi wrapper (no colmena here), which applies the RPi overlays
  # and injects the `nixos-raspberrypi` specialArg. The `sd-image` module yields
  # `config.system.build.sdImage`; `workDir` forwards the consumer admin pubkey.
  sdImageNixosConfigurations = builtins.listToAttrs (
    map (board: {
      name = "sd-image-${board}";
      value = nixos-raspberrypi.lib.nixosSystem {
        specialArgs = { inherit workDir nixos-raspberrypi; };
        modules = [
          nixos-raspberrypi.nixosModules.${board}.base
          nixos-raspberrypi.nixosModules.sd-image
          ../hosts/sd-image.nix
        ];
      };
    }) rpiBoards
  );

  # Multi-arch devshell (cargo / nix-unit / sops / colmena / ...).
  # Shared with the framework's own shell — see lib/dev-shell.nix.
  mkDevShell =
    system:
    import ./dev-shell.nix {
      pkgs = nixpkgsFor.${system};
      inherit (inputs.colmena.packages.${system}) colmena;
    };

in
{

  # Public node API — single source of truth for nixosConfigurations,
  # colmena, tests and install (see spec §9).
  inherit mkNodes;

  colmena = colmenaSet;
  colmenaHive = colmena.lib.makeHive colmenaSet;

  nixosConfigurations =
    isoNixosConfigurations // sdImageNixosConfigurations // consumerNixosConfigurations;

  # Plan of `just configure-admin-host` (`just/scripts/generate-secrets.sh`).
  # Each host's `sops.secrets` is the authority on which secrets exist; `key`
  # addresses the YAML, so aliases collapse onto their source entry.
  secretsPlan = dnfLibFor.x86_64-linux.mkSecretPlan (
    nixpkgs.lib.concatMap (
      node: map (secret: secret.key) (nixpkgs.lib.attrValues node.config.sops.secrets)
    ) (nixpkgs.lib.attrValues consumerNixosConfigurations)
  );

  devShells = forAllSystems (system: {
    default = mkDevShell system;
  });

  # DNF-only packages (`pkgs/`) against the consumer's own lock: `nix run
  # .#fleet-update` works without the module or a framework checkout.
  packages = forAllSystems (system: import ../pkgs { pkgs = nixpkgsFor.${system}; });

  # `nix run .#init` — (re)link `dnf/` onto the framework revision this project
  # pins in its own flake.lock. Run it after every `nix flake update dnf`, so
  # the just recipes and the generator profiles stay in sync with what is built.
  apps = forAllSystems (system: {
    init = import ./init-app.nix {
      pkgs = nixpkgsFor.${system};
      frameworkRoot = inputs.self;
    };
  });
}
