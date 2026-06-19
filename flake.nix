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
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena/main";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # L4 install tier — `nixos-anywhere --flake .#<host> --vm-test` exposed
    # as a deterministic `.#checks` entry through `tests/lib/mkInstallTest.nix`.
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Code — always-up-to-date native binary from Anthropic.
    # Auto-updated hourly by the upstream flake; no version pin.
    # NOTE: evaluation warning: 'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'
    claude-code.url = "github:sadjow/claude-code-nix";
    claude-code.inputs.nixpkgs.follows = "nixpkgs";

    # RPI5 + hardware optims.
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";

    # Geneweb : suivi de la PR nixpkgs#522751 (module + paquetage `geneweb`
    # en attente de merge). Voir `lib/overlays/geneweb.nix`.
    #
    # Quand la PR est mergée dans `nixos-unstable` :
    #   1. Supprimer cet input,
    #   2. Supprimer `lib/overlays/geneweb.nix` et son usage dans `lib/mk-configuration.nix`,
    #   3. Retirer le path du module upstream de la `modules` list de `mkNode`.
    # Le wrapper `modules/service/geneweb.nix` reste inchangé.
    #
    # Pas de `inputs.nixpkgs.follows` : on veut le tree complet du fork
    # (sinon l'overlay reconstruirait `geneweb` sur un nixpkgs sans les
    # dépendances OCaml ajoutées par la PR).
    nixpkgs-geneweb.url = "github:darkone-linux/nixpkgs/create-geneweb";

    # OxiCloud : suivi de la PR nixpkgs#516113 (module NixOS uniquement ; le
    # paquet `oxicloud` est déjà dans `nixos-unstable`, pas d'overlay).
    #
    # Quand la PR est mergée dans `nixos-unstable` :
    #   1. Supprimer cet input,
    #   2. Retirer le path du module upstream de la `modules` list de `mkNode`.
    # Le wrapper `modules/service/oxicloud.nix` reste inchangé.
    #
    # Pas de `inputs.nixpkgs.follows` : on source l'arbre du fork tel quel
    # (cf. nixpkgs-geneweb).
    nixpkgs-oxicloud.url = "github:flashonfire/nixpkgs/oxicloud-service";

    # Rust generator (`dnf-generator`). Default points at the public release
    # repo; consumers in co-dev (arthur-network) can override with a path or
    # `git+file://` URL to pick up local changes:
    #   --override-input dnf/dnf-generator path:./src/generator
    dnf-generator.url = "github:darkone-linux/dnf-generator";
    dnf-generator.inputs.nixpkgs.follows = "nixpkgs";
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
        # "aarch64-linux"
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

              # Standalone framework ISO: no consumer workspace. `hosts/iso.nix`
              # declares `workDir ? null` but the module system bypasses that
              # default and queries `_module.args.workDir`; inject it explicitly.
              workDir = null;
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

      #------------------------------------------------------------------------
      # PACKAGES
      #------------------------------------------------------------------------
      #
      # Surface artefacts consumers fetch without a local checkout of the
      # framework. `dnf-generator` re-exposes the Rust binary built by the
      # `dnf-generator` flake input. `assets` packages the shared Justfile
      # recipes (`just/project.just`) so a consumer can symlink them into
      # `.dnf/` via `nix run .#init` and then `import? '.dnf/just/project.just'`
      # from its own Justfile.

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          dnf-generator = inputs.dnf-generator.packages.${system}.default;

          assets = pkgs.runCommand "dnf-assets" { } ''
            mkdir -p $out
            cp -r ${./assets}/. $out/
          '';
        }
      );

      #------------------------------------------------------------------------
      # APPS
      #------------------------------------------------------------------------
      #
      # `init` materialises the `assets` derivation as a `.dnf/` symlink in
      # the consumer's workspace. Required because `just` resolves `import`
      # paths statically at parse time — there is no shell substitution that
      # could fetch the store path on the fly.
      #
      # Usage from a consumer project:
      #   nix run github:darkone-linux/darkone-nixos-framework#init

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          init = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "dnf-init" ''
                set -euo pipefail
                ln -sfn ${self.packages.${system}.assets} .dnf
                echo "Linked .dnf -> $(readlink .dnf)"
              ''
            );
          };
        }
      );

      # Unit tests — run with: nix-unit --flake .#libTests
      libTests = import ./tests/unit { inherit (nixpkgs) lib; };

      # Simulation tests (NixOS Test Driver) — auto-discovered from
      # tests/scenarios/. Run a single one: just simulate <name>.
      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        import ./tests/scenarios { inherit pkgs inputs; }
      );

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
            packages = [
              self.packages.${system}.dnf-generator
            ]
            ++ (with pkgs; [
              age
              cargo
              colmena
              d2
              deadnix
              git
              just
              mkpasswd
              nix-output-monitor
              nix-unit
              nixfmt
              openssl
              rustc
              treefmt
              sops
              ssh-to-age
              statix
              wipe
              yq-go
              zsh
            ]);
            shellHook = "exec zsh";
          };
        }
      );

    }; # outputs
}
