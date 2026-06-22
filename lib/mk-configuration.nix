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
    home-manager
    colmena
    sops-nix
    disko
    nixos-raspberrypi
    ;

  # NixOS state version applied to fresh hosts/homes
  unstableStateVersion = "26.05";

  supportedSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

  # Pure helpers; needed before mkDnfLib (arch-independent)
  hiveLib = import ./hive.nix { inherit (nixpkgs) lib; };
  inherit (hiveLib)
    getHostArch
    getHostBoard
    mkNodeArgs
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

  # Overlay temporaire : injecte `pkgs.geneweb` depuis la PR nixpkgs#522751.
  # À supprimer en même temps que l'input `nixpkgs-geneweb` (cf. flake.nix).
  # Appliqué via `nixpkgs.overlays` dans `mkNode` plutôt que dans `nixpkgsFor` :
  # `nixosSystem` reconstruit son propre `pkgs`, donc seul `nixpkgs.overlays`
  # passé en module atteint le `pkgs` vu par les modules.
  genewebOverlay = import ./overlays/geneweb.nix { inherit nixpkgs-geneweb; };

  # Overlay portabilité : neutralise le `target-cpu=native` d'OxiCloud pour que
  # le binaire construit sur le deployer tourne sur tous les nœuds (SIGILL
  # sinon sur CPU plus ancien). À retirer si le paquet nixpkgs le corrige.
  oxicloudOverlay = import ./overlays/oxicloud.nix;

  # Overlay compat : force `__structuredAttrs = false` sur `gimp` (build cassé
  # sinon). À retirer dès qu'amont rend `gimp` compatible `__structuredAttrs`.
  gimpOverlay = import ./overlays/gimp.nix;

  # Per-system nixpkgs instances
  nixpkgsFor = forAllSystems (
    system:
    import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    }
  );

  nixpkgsStableFor = forAllSystems (
    system:
    import nixpkgs-stable {
      inherit system;
      config.allowUnfree = true;
    }
  );

  # DNF runtime lib (per-system, injected into modules via specialArgs.dnfLib)
  mkDnfLib =
    system:
    let
      pkgs = nixpkgsFor.${system};
    in
    import ./. { inherit (pkgs) lib; };

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
  mkCommonNodeArgs = system: {
    inherit
      dnfConfig
      network
      users
      userNixosProfiles
      workDir
      ;
    pkgs-stable = nixpkgsStableFor.${system};
    dnfLib = mkDnfLib system;

    # Required by nixos-raspberrypi board modules to locate the flake (the same
    # specialArg its `lib.nixosSystem` wrapper would inject).
    inherit nixos-raspberrypi;
  };

  mkNodeSpecialArgs = host: {
    name = host.hostname;
    value = mkNodeArgs {
      inherit host hosts network;
      extraArgs = mkCommonNodeArgs (getHostArch host);
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
    in
    {
      inherit system;
      specialArgs = nodeSpecialArgs.${host.hostname};
      modules = [

        # Framework-side NixOS modules
        ../modules

        # Geneweb : module upstream importé depuis la PR nixpkgs#522751
        # (à retirer dès que la PR est mergée dans `nixos-unstable`).
        # Parsé inconditionnellement mais sans effet tant que
        # `services.geneweb.enable = false`.
        "${nixpkgs-geneweb}/nixos/modules/services/web-apps/geneweb.nix"

        # Overlays temporaires (à retirer en même temps que les imports/inputs
        # upstream correspondants) :
        #
        # - geneweb   : injecte `pkgs.geneweb` depuis la PR nixpkgs#522751 ;
        # - oxicloud  : neutralise `target-cpu=native` pour un binaire portable
        #               entre nœuds (cf. oxicloudOverlay ci-dessus) ;
        # - gimp      : force `__structuredAttrs = false` (build cassé sinon).
        {
          nixpkgs.overlays = [
            (genewebOverlay system)
            oxicloudOverlay
            gimpOverlay
          ];
        }

        # OxiCloud : module upstream importé depuis la PR nixpkgs#516113
        # (à retirer dès que la PR est mergée dans `nixos-unstable`). Parsé
        # inconditionnellement, sans effet tant que `services.oxicloud.enable`
        # reste à false. Pas d'overlay : `pkgs.oxicloud` vient déjà du tree
        # `nixpkgs` principal.
        "${nixpkgs-oxicloud}/nixos/modules/services/web-apps/oxicloud.nix"

        # Consumer-side NixOS modules overlay
        (workDir + "/usr/modules")
      ]

      # The test driver provides its own nixpkgs/system layer.
      ++ nixpkgs.lib.optional (!forTest) "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
      ++ [
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
        {

          # Silence the upstream warning on fresh hosts. Hosts that own a
          # `usr/machines/<host>/default.nix` keep pinning their own value;
          # `mkDefault` lets them win.
          system.stateVersion = nixpkgs.lib.mkDefault unstableStateVersion;
        }
        {
          home-manager = {

            # Reuse global pkgs from nixpkgs
            useGlobalPkgs = true;

            # Install in /etc/profiles instead of ~/.nix-profile
            useUserPackages = true;

            # Backup colliding files (e.g. .zshrc) instead of failing.
            # LIMITATION: bails if a .bkp already exists.
            backupFileExtension = "bkp";

            users = builtins.listToAttrs (map mkHome host.users);

            extraSpecialArgs = mkNodeArgs {
              inherit host hosts network;
              extraArgs = mkCommonNodeArgs system // {
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
      ++ nixpkgs.lib.optional (builtins.pathExists (workDir + "/usr/machines/${host.hostname}")) (
        workDir + "/usr/machines/${host.hostname}"
      );
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
        (import (resolveProfile users.${login}.profile))
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
  rpiBoards = [
    "raspberry-pi-5"
    "raspberry-pi-4"
    "raspberry-pi-3"
    "raspberry-pi-02"
  ];
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

  # Multi-arch devshell (cargo / nix-unit / sops / colmena / ...)
  mkDevShell =
    system:
    let
      pkgs = nixpkgsFor.${system};
      inherit (inputs.colmena.packages.${system}) colmena;
    in
    pkgs.mkShell {
      packages = with pkgs; [
        age
        cargo
        colmena
        deadnix
        git
        just
        mkpasswd
        nix-unit
        nixfmt
        openssl
        rustc
        treefmt
        sops
        ssh-to-age
        statix
        yq-go
        zsh
      ];
      shellHook = "exec zsh";
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

  devShells = forAllSystems (system: {
    default = mkDevShell system;
  });
}
