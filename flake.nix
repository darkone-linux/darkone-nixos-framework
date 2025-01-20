{
  description = "NixOS Darkone Framework";

  # Usefull cache for colmena
  nixConfig = {
    extra-trusted-substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      colmena,
      nixos-generators,
      ...
    }:

    let

      # Main system
      system = "x86_64-linux";

      # Start img common configuration
      startImgParams = {
        inherit system;
        modules = [
          {
            # Pin nixpkgs to the flake input, so that the packages installed
            # come from the flake inputs.nixpkgs.url.
            nix.registry.nixpkgs.flake = nixpkgs;

            # set disk size to to 20G
            virtualisation.diskSize = 20 * 1024;
          }
          ./lib/modules
        ];
      };

      # The hosts.nix generated file (just generate)
      hosts = import ./var/generated/hosts.nix;

      # Global network configuration
      network = import ./var/generated/network.nix;

      mkHome = user: {
        name = user.login;
        value = {
          imports = [ (import ./${user.profile}) ];

          # Home profiles loading
          home = {
            username = user.login;
            homeDirectory = nixpkgs.lib.mkForce "/home/${user.login}";
            stateVersion = "25.05";
          };
        };
      };

      mkNodeSpecialArgs = host: {
        name = host.hostname;
        value = {
          "host" = host;
          "network" = network;
          "imgFormat" = nixpkgs.lib.mkDefault "iso";
        };
      };

      mkHost = host: {
        name = host.hostname;
        value = host.colmena // {
          imports =
            [
              ./lib/modules
              ./usr/modules
              home-manager.nixosModules.home-manager
              {
                home-manager = {

                  # Use global packages from nixpkgs
                  useGlobalPkgs = true;

                  # Install in /etc/profiles instead of ~/nix-profiles.
                  useUserPackages = true;

                  # Load users profiles
                  users = builtins.listToAttrs (map mkHome host.users);

                  extraSpecialArgs = {
                    inherit host;

                    # This hack must be set to allow unfree packages
                    # in home manager configurations.
                    # useGlobalPkgs with allowUnfree nixpkgs do not works.
                    pkgs = import nixpkgs {
                      inherit system;
                      config.allowUnfree = true;
                    };
                  };
                };
              }
            ]
            ++ nixpkgs.lib.optional (builtins.pathExists ./usr/machines/${host.hostname}) ./usr/machines/${host.hostname};
        };
      };

    in
    {
      colmena = {
        meta = {
          description = "Darkone Framework Network";
          nixpkgs = import nixpkgs {
            system = "x86_64-linux";
            allowUnfree = true;
            allowUnfreePredicate = _: true;
            overlays = [ ];
          };
          nodeSpecialArgs = builtins.listToAttrs (map mkNodeSpecialArgs hosts);
        };

        # Default deployment settings
        defaults.deployment = {
          buildOnTarget = nixpkgs.lib.mkDefault false;
          allowLocalDeployment = nixpkgs.lib.mkDefault true;
          targetUser = "nix";
          #sshOptions = [
          #  "-i"
          #  "/etc/nixos/var/security/ssh/id_ed25519_nix"
          #];

          # Override the default for this target host
          # Darkone framework : declare the new host before apply
          replaceUnknownProfiles = false;
        };
      } // builtins.listToAttrs (map mkHost hosts);

      # Start images generators
      # TODO: factorize
      packages.x86_64-linux = {
        start-img-iso = nixos-generators.nixosGenerate (
          startImgParams
          // {
            format = "iso";
            specialArgs = {
              imgFormat = "iso";
              host = {
                hostname = "ndf-start-iso";
                name = "Darkone Network Start ISO";
                profile = "start-img";
                users = [];
              };
            };
          }
        );
        start-img-vbox = nixos-generators.nixosGenerate (
          startImgParams
          // {
            format = "virtualbox";
            specialArgs = {
              imgFormat = "vbox";
              host = {
                hostname = "ndf-start-vbox";
                name = "Darkone Network Start Virtualbox IMG";
                profile = "start-img";
                users = [];
              };
            };
          }
        );
      };

    }; # outputs
}
