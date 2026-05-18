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
#
# Aim: configure, use, maintain.

{ inputs }:
workDir:

let
  inherit (inputs)
    nixpkgs
    nixpkgs-stable
    home-manager
    colmena
    sops-nix
    disko
    nixos-hardware
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
  inherit (hiveLib) getHostArch mkNodeArgs;

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
  network = import (workDir + "/var/generated/network.nix");

  # Profile paths in `users.nix` can target either the framework
  # (legacy `dnf/...` prefix from the generator) or the consumer's workDir
  # (e.g. `usr/home/profiles/...`). Resolve both transparently.
  resolveProfile =
    profilePath:
    if nixpkgs.lib.hasPrefix "dnf/" profilePath then
      ./.. + "/${nixpkgs.lib.removePrefix "dnf/" profilePath}"
    else
      workDir + "/${profilePath}";

  # Each user profile has a companion NixOS module (e.g.
  # `home/nixos/<name>.nix`) defining its `users.users.<login>` overrides.
  # Pre-resolve those paths so `modules/user/build.nix` is layout-agnostic.
  resolveNixosProfile =
    profilePath:
    let
      name = baseNameOf profilePath;
    in
    if nixpkgs.lib.hasPrefix "dnf/" profilePath then
      ./../home/nixos + "/${name}.nix"
    else
      workDir + "/usr/home/nixos/${name}.nix";

  userNixosProfiles = nixpkgs.lib.mapAttrs (_login: user: resolveNixosProfile user.profile) users;

  # Common args injected as specialArgs / extraSpecialArgs.
  # `workDir` lets framework modules reference consumer-side files
  # (`usr/secrets/...`, `usr/www/...`) without baking relative paths.
  mkCommonNodeArgs = system: {
    inherit
      network
      users
      userNixosProfiles
      workDir
      ;
    pkgs-stable = nixpkgsStableFor.${system};
    dnfLib = mkDnfLib system;
  };

  mkNodeSpecialArgs = host: {
    name = host.hostname;
    value = mkNodeArgs {
      inherit host hosts network;
      extraArgs = mkCommonNodeArgs (getHostArch host);
    };
  };

  nodeSpecialArgs = builtins.listToAttrs (map mkNodeSpecialArgs hosts);

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

  # One Colmena host descriptor
  mkHost = host: {
    name = host.hostname;
    value = host.colmena // {
      nixpkgs.hostPlatform.system = getHostArch host;
      imports = [

        # Framework-side NixOS modules
        ../modules

        # Consumer-side NixOS modules overlay
        (workDir + "/usr/modules")

        "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
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
              extraArgs = mkCommonNodeArgs (getHostArch host) // {
                inherit inputs;
              };
            };
          };
        }
      ]
      ++ nixpkgs.lib.optional (
        getHostArch host == "aarch64-linux"
      ) nixos-hardware.nixosModules.raspberry-pi-5
      ++ nixpkgs.lib.optional (builtins.pathExists (workDir + "/usr/machines/${host.hostname}")) (
        workDir + "/usr/machines/${host.hostname}"
      );
    };
  };

  # Colmena hive description (consumed both by `colmena` CLI and the derived
  # nixosConfigurations).
  colmenaSet = {
    meta = {
      description = "Darkone Framework Network";
      nixpkgs = nixpkgsFor.x86_64-linux;
      inherit nodeSpecialArgs;
    };
    defaults.deployment = {
      buildOnTarget = nixpkgs.lib.mkDefault false;
      allowLocalDeployment = nixpkgs.lib.mkDefault true;
      replaceUnknownProfiles = true;
      targetUser = "nix";
    };
  }
  // builtins.listToAttrs (map mkHost hosts);

  # Standalone nixosSystem evaluations (built by nixos-rebuild / nix build)
  consumerNixosConfigurations =
    builtins.mapAttrs
      (
        name: node:
        nixpkgs.lib.nixosSystem {
          inherit (node.nixpkgs.hostPlatform) system;
          specialArgs = nodeSpecialArgs.${name};
          modules = node.imports;
        }
      )
      (
        removeAttrs colmenaSet [
          "meta"
          "defaults"
        ]
      );

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
        moreutils
        nix-unit
        nixfmt
        rustc
        sops
        ssh-to-age
        statix
        yq
        zsh
      ];
      shellHook = "exec zsh";
    };

in
{
  colmena = colmenaSet;
  colmenaHive = colmena.lib.makeHive colmenaSet;

  nixosConfigurations = isoNixosConfigurations // consumerNixosConfigurations;

  devShells = forAllSystems (system: {
    default = mkDevShell system;
  });
}
