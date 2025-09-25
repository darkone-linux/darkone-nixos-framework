{
  description = "NixOS Darkone Framework";

  nixConfig = {
    extra-trusted-substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    raspberry-pi-nix = {
      url = "github:nix-community/raspberry-pi-nix?ref=v0.4.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      home-manager,
      raspberry-pi-nix,
      nixos-hardware,
      sops-nix,
      ...
    }:
    let

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

      mkHome = login: {
        name = login;
        value = {
          imports = [
            ./dnf/modules/home
            (import ./${users.${login}.profile})
          ];

          # Home profiles loading
          home = {
            username = login;
            homeDirectory = nixpkgs.lib.mkDefault "/home/${login}";
            stateVersion = "25.05";
          };
        };
      };

      # Generate common args for each architecture
      mkCommonNodeArgs = system: {
        inherit users;
        inherit network;
        inherit system;
        imgFormat = nixpkgs.lib.mkDefault "iso";
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

      mkHost = host: {
        name = host.hostname;
        value = host.colmena // {
          nixpkgs.system = getHostArch host;
          imports = [
            ./dnf/modules/nix
            ./usr/modules/nix
            "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
            sops-nix.nixosModules.sops
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
                  system = getHostArch host;
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
          ];
        };

    in
    {
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

      # Iso image for first install DNF system
      # nix build .#nixosConfigurations.iso.config.system.build.isoImage
      nixosConfigurations = builtins.listToAttrs (
        map (system: {
          name =
            if system == "x86_64-linux" then "iso" else "iso-${builtins.replaceStrings [ "-" ] [ "_" ] system}";
          value = nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = mkCommonNodeArgs system // {
              host = {
                hostname = "new-dnf";
                name = "New Darkone NixOS Framework";
                profile = "minimal";
                users = [ "nix" ];
                groups = [ ];
                arch = system;
              };
            };
            modules = [
              "${nixpkgs}/nixos/modules/misc/nixpkgs.nix"
              sops-nix.nixosModules.sops
              home-manager.nixosModules.home-manager
              ./dnf/hosts/iso.nix
              { nixpkgs.pkgs = nixpkgsFor.${system}; }
            ];
          };
        }) supportedSystems
      );

      # Dev env for all supported architectures
      devShells = forAllSystems (system: {
        default = mkDevShell system;
      });

      # Darkone modules
      nixosModules = {
        darkone = ./dnf/modules/nix;
        default = self.nixosModules.darkone;
      };
      homeManagerModules = {
        darkone = ./dnf/modules/home;
      };
    }; # outputs
}
