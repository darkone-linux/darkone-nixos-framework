{
  description = "NixOS Darkone Framework";

  #----------------------------------------------------------------------------
  # CACHING
  #----------------------------------------------------------------------------

  nixConfig = {
    extra-trusted-substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  #----------------------------------------------------------------------------
  # FLAKE INPUTS
  #----------------------------------------------------------------------------

  inputs = {

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    raspberry-pi-nix = {
      url = "github:nix-community/raspberry-pi-nix?ref=v0.4.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  #----------------------------------------------------------------------------
  # FLAKE OUTPUTS
  #----------------------------------------------------------------------------

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      home-manager,
      raspberry-pi-nix,
      nixos-hardware,
      nix-flatpak,
      sops-nix,
      disko,
      ...
    }@inputs:
    let

      #------------------------------------------------------------------------
      # OUTPUT LET
      #------------------------------------------------------------------------

      # Unstable state version for new hosts / homes installations
      unstableStateVersion = "25.11";

      # Support for multiple architectures
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Function to get host architecture from host config or default to x86_64-linux
      getHostArch = host: host.arch or "x86_64-linux";

      # Per-system initialization of pkgs
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.allowUnfreePredicate = _: true;
          overlays = [ ];
        }
      );

      nixpkgsStableFor = forAllSystems (
        system:
        import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        }
      );

      # Generated files (with just generate)
      hosts = import ./var/generated/hosts.nix;
      users = import ./var/generated/users.nix;
      network = import ./var/generated/network.nix;

      # Home manager context creations
      mkHome = login: {
        name = login;
        value = {
          imports = [
            nix-flatpak.homeManagerModules.nix-flatpak
            ./dnf/home/modules
            ./usr/users/${login}
            (import ./${users.${login}.profile})
          ];

          # Home profiles loading - TODO: stateVersion must be fixed for each user at creation
          home = {
            username = login;
            homeDirectory = nixpkgs.lib.mkDefault "/home/${login}";
            stateVersion = nixpkgs.lib.mkDefault "${unstableStateVersion}";
          };
        };
      };

      # Generate common args for each architecture
      mkCommonNodeArgs = system: {
        inherit users;
        inherit network;
        pkgs-stable = nixpkgsStableFor.${system};
      };

      mkNodeSpecialArgs = host: {
        name = host.hostname;
        value = {
          inherit host;
          inherit network;
        }
        // mkCommonNodeArgs (getHostArch host);
      };
      nodeSpecialArgs = builtins.listToAttrs (map mkNodeSpecialArgs hosts);

      # Host creation
      mkHost = host: {
        name = host.hostname;
        value = host.colmena // {
          nixpkgs.system = getHostArch host;
          imports = [
            ./dnf/modules
            ./usr/modules
            "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            nix-flatpak.nixosModules.nix-flatpak
            { _module.args.dnfLib = mkDnfLib (getHostArch host); }
            home-manager.nixosModules.home-manager
            {
              home-manager = {

                # Use global packages from nixpkgs
                useGlobalPkgs = true;

                # Install in /etc/profiles instead of ~/nix-profiles.
                useUserPackages = true;

                # Avoid error on replacing a file (.zshrc for example)
                # LIMITATION: if bkp file already exists -> fail
                backupFileExtension = "bkp";

                # Load users profiles
                users = builtins.listToAttrs (map mkHome host.users);

                extraSpecialArgs = {
                  inherit network;
                  inherit host;
                  inherit users;
                  inherit inputs;
                  pkgs-stable = nixpkgsStableFor.${getHostArch host};
                };
              };
            }
          ]
          ++ nixpkgs.lib.optional (
            getHostArch host == "aarch64-linux"
          ) raspberry-pi-nix.nixosModules.raspberry-pi
          ++ nixpkgs.lib.optional (
            getHostArch host == "aarch64-linux"
          ) nixos-hardware.nixosModules.raspberry-pi-5
          ++ nixpkgs.lib.optional (builtins.pathExists ./usr/machines/${host.hostname}) ./usr/machines/${host.hostname};
        };
      };

      # Multi-arch devshells
      mkDevShell =
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        pkgs.mkShell {
          buildInputs = with pkgs; [
            age
            colmena
            deadnix
            git
            just
            mkpasswd
            moreutils # sponge
            nixfmt-rfc-style
            php84
            php84Packages.composer
            sops
            ssh-to-age
            statix
            yq
            zsh
          ];
        };

      # DNF tools
      mkDnfLib =
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        import ./dnf/lib { inherit (pkgs) lib; };

    in
    {
      #------------------------------------------------------------------------
      # HOSTS MANAGEMENT WITH COLMENA
      #------------------------------------------------------------------------

      #colmenaHive = colmena.lib.makeHive self.outputs.colmena;
      colmena = {
        meta = {
          description = "Darkone Framework Network";
          nixpkgs = nixpkgsFor.x86_64-linux; # default system
          inherit nodeSpecialArgs;
        };

        # Default deployment settings
        defaults.deployment = {
          buildOnTarget = nixpkgs.lib.mkDefault false;
          allowLocalDeployment = nixpkgs.lib.mkDefault true;
          replaceUnknownProfiles = true;
          targetUser = "nix";
        };
      }
      // builtins.listToAttrs (map mkHost hosts);

      #------------------------------------------------------------------------
      # ISO IMAGE
      #------------------------------------------------------------------------

      # Iso image for first install DNF system
      # nix build .#nixosConfigurations.iso.config.system.build.isoImage
      nixosConfigurations =
        (builtins.listToAttrs (
          map (system: {
            name = "iso-${system}";
            value = nixpkgs.lib.nixosSystem {
              #inherit system;
              specialArgs = {
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
                #"${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
                { nixpkgs.pkgs = nixpkgsFor.${system}; }
                ./dnf/hosts/iso.nix
              ];
            };
          }) supportedSystems
        ))
        //
          builtins.mapAttrs
            (
              name: node:
              (nixpkgs.lib.nixosSystem {
                inherit (node.nixpkgs) system;
                specialArgs = nodeSpecialArgs.${name};
                modules = node.imports;
              })
            )
            (
              removeAttrs self.colmena [
                "meta"
                "defaults"
              ]
            );

      #------------------------------------------------------------------------
      # DEV SHELL
      #------------------------------------------------------------------------

      # Dev env for all supported architectures
      devShells = forAllSystems (system: {
        default = mkDevShell system;
      });

      #------------------------------------------------------------------------
      # DNF USEFUL OUTPUTS
      #------------------------------------------------------------------------

      # Darkone modules
      nixosModules = {
        darkone = ./dnf/modules;
        default = self.nixosModules.darkone;
      };
      homeManagerModules = {
        darkone = ./dnf/home/modules;
      };

      # DNF library for leaf flakes
      lib = forAllSystems mkDnfLib;
    }; # outputs
}
