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

      # Generated files (with just generate)
      hosts = import ./var/generated/hosts.nix;
      users = import ./var/generated/users.nix;
      networks = import ./var/generated/networks.nix;

      mkHome = login: {
        name = login;
        value = {
          imports = [
            ./lib/home-modules
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

      extractDefaultNetwork =
        host:
        if (nixpkgs.lib.lists.count (_: true) host.networks) > 0 then
          builtins.elemAt host.networks 0
        else
          "default";

      commonNodeArgs = {
        inherit users;
        inherit networks;
        imgFormat = nixpkgs.lib.mkDefault "iso";
        pkgs-stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };
      };

      mkNodeSpecialArgs = host: {
        name = host.hostname;
        value =
          let
            networkId = extractDefaultNetwork host;
          in
          {
            inherit host;
            network = networks.${networkId} // {
              id = networkId;
            };
          }
          // commonNodeArgs;
      };
      nodeSpecialArgs = builtins.listToAttrs (map mkNodeSpecialArgs hosts);

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

                  # Avoid error on replacing a file (.zshrc for example)
                  # LIMITATION: if bkp file already exists -> fail
                  backupFileExtension = "bkp";

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
          inherit nodeSpecialArgs;
        };

        # Default deployment settings
        defaults.deployment = {
          buildOnTarget = nixpkgs.lib.mkDefault false;
          allowLocalDeployment = nixpkgs.lib.mkDefault true;
          replaceUnknownProfiles = true;
          targetUser = "nix";

          # DO NOT WORKS
          #sshOptions = [
          #  "-i"
          #  "/etc/nixos/var/security/ssh/id_ed25519_nix"
          #];
        };
      } // builtins.listToAttrs (map mkHost hosts);

      # Iso image for first install DNF system
      # nix build .#nixosConfigurations.iso.config.system.build.isoImage
      nixosConfigurations = {
        iso = nixpkgs.lib.nixosSystem {
          specialArgs = {
            host = {
              hostname = "new-dnf";
              name = "New Darkone NixOS Framework";
              profile = "minimal";
              users = [ "nix" ];
              groups = [ ];
            };
          } // commonNodeArgs;
          modules = [ ./lib/hosts/iso.nix ];
        };
      };
    }; # outputs
}
