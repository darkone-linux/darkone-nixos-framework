{
  description = "Darkone NixOS Framework — declarative, reproducible multi-host NixOS for self-hosted networks.";

  #----------------------------------------------------------------------------
  # CACHING
  #----------------------------------------------------------------------------

  # nixConfig = {
  #   extra-trusted-substituters = [
  #     "https://cache.garnix.io"
  #     "https://nix-community.cachix.org"
  #   ];
  #   extra-trusted-public-keys = [
  #     "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  #     "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  #   ];
  # };

  #----------------------------------------------------------------------------
  # FLAKE INPUTS
  #----------------------------------------------------------------------------

  inputs = {

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  #----------------------------------------------------------------------------
  # FLAKE OUTPUTS
  #----------------------------------------------------------------------------

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let

      # `mkConfigurations` is the public entry point consumed by consumer
      # flakes (arthur-network, dnf-boilerplate). It closes over the framework
      # `inputs` declared above and only requires the consumer's `workDir`.
      mkConfigurations = import ./lib/mk-configuration.nix { inherit inputs; };

      # Build the framework's own "self" configuration (used by the framework's
      # standalone outputs: ISO images, libTests, devShell). It points at the
      # framework dir itself; consumer-side paths (`workDir/usr`,
      # `workDir/var/generated`) are NOT touched here — the standalone flake
      # only exposes framework-owned outputs.
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    in
    {

      #------------------------------------------------------------------------
      # PUBLIC API FOR CONSUMERS
      #------------------------------------------------------------------------

      # Consumers call `inputs.dnf.lib.mkConfigurations ./.` from their flake.
      lib.mkConfigurations = mkConfigurations;

      #------------------------------------------------------------------------
      # FRAMEWORK-OWNED OUTPUTS (no consumer workDir required)
      #------------------------------------------------------------------------

      # NixOS modules exposed for consumers that want to opt-in piecewise.
      nixosModules = {
        darkone = ./modules;
        default = self.nixosModules.darkone;
      };

      homeManagerModules = {
        darkone = ./home/modules;
      };

      # ISO images — buildable standalone from the framework flake.
      # `nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage`
      nixosConfigurations = builtins.listToAttrs (
        map (system: {
          name = "iso-${system}";
          value = nixpkgs.lib.nixosSystem {
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
              {
                nixpkgs.pkgs = import nixpkgs {
                  inherit system;
                  config.allowUnfree = true;
                };
              }
              ./hosts/iso.nix
            ];
          };
        }) supportedSystems
      );

      # Unit tests — run with: nix-unit --flake .#libTests
      libTests = import ./tests/unit { inherit (nixpkgs) lib; };

      # Dev shell for framework hacking (cargo / nix-unit / sops / ...).
      # Identical to the one consumers get via mkConfigurations.
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          inherit (inputs.colmena.packages.${system}) colmena;
        in
        {
          default = pkgs.mkShell {
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
        }
      );

    }; # outputs
}
