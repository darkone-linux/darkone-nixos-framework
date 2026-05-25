# Standalone test mode for the NixOS Test Driver.
#
# When enabled, neutralizes the irreducibly external/runtime bits so a node
# can be exercised in a VM: headscale/tailscale become no-ops and a fixed
# TLS cert can stub ACME. It also lets workDir-only config (nix.pub,
# harmonia.pub) be skipped by core/ncps. sops stays REAL (high fidelity).
#
# :::caution[Tests only]
# Enabled only via `tests/lib/test-tuning.nix`. This module never references
# any path under `tests/` — the cert path is passed as an option value.
# :::
#
# Aim: use, debug.

{ lib, config, ... }:
let
  cfg = config.darkone.test;
in
{
  options.darkone.test = {
    standalone = lib.mkEnableOption "Standalone test mode — skip workDir-only config (nix.pub, harmonia.pub) and neutralize external services";

    tlsCert = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Self-signed cert (PEM) provided by the test harness to stub ACME. Never a tests/ path baked into the framework.";
    };

    tlsKey = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Private key (PEM) paired with tlsCert.";
    };
  };

  config = lib.mkIf cfg.standalone {

    # VPN coordination + mesh are out of scope in VM tests.
    services.headscale.enable = lib.mkForce false;
    services.tailscale.enable = lib.mkForce false;
  };
}
