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
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-stable,
      home-manager,
      colmena,
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

      # Generated files (with just generate)
      hosts = import ./var/generated/hosts.nix;
      users = import ./var/generated/users.nix;
      networks = import ./var/generated/networks.nix;

      mkHome = login: {
        name = login;
        value = {
          imports = [ (import ./${users.${login}.profile}) ];

          # Home profiles loading
          home = {
            username = login;
            homeDirectory = nixpkgs.lib.mkDefault "/home/${login}";
            stateVersion = "25.05";
          };
        };
      };

      extractDefaultNetwork =
        host:
        if (nixpkgs.lib.lists.count (_: true) host.networks) > 0 then
          builtins.elemAt host.networks 0
        else
          "default";

      mkNodeSpecialArgs = host: {
        name = host.hostname;
        value =
          let
            networkId = extractDefaultNetwork host;
          in
          {
            inherit host;
            inherit users;
            inherit networks;
            network = networks.${networkId} // {
              id = networkId;
            };
            imgFormat = nixpkgs.lib.mkDefault "iso";
            pkgs-stable = import nixpkgs-stable {
              inherit system;
              config.allowUnfree = true;
            };
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

                  extraSpecialArgs =
                    let
                      networkId = extractDefaultNetwork host;
                    in
                    {
                      inherit host;
                      inherit users;
                      network = networks.${networkId} // {
                        id = networkId;
                      };

                      # This hack must be set to allow unfree packages
                      # in home manager configurations.
                      # useGlobalPkgs with allowUnfree nixpkgs do not works.
                      pkgs = import nixpkgs {
                        inherit system;
                        config.allowUnfree = true;
                      };
                      pkgs-stable = import nixpkgs-stable {
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
    }; # outputs
}
