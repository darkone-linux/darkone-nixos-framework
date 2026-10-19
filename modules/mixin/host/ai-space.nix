# AI space: headless host running the agents of one space (owner + members).
#
# Server base with secrets isolated from the fleet: agents read untrusted
# input (mail, web, chat), so the host only decrypts its own
# `usr/secrets/hosts/<hostname>.yaml`. Usually a microVM guest
# (`features: ["microvm-guest:<hypervisor>"]`), bare metal works too.

{ lib, config, ... }:
let
  cfg = config.darkone.host.ai-space;
in
{
  options = {
    darkone.host.ai-space.enable = lib.mkEnableOption "AI space host (isolated agents workspace)";
  };

  config = lib.mkIf cfg.enable {

    # Services of `host.services` are triggered by the server profile.
    darkone.host.server.enable = true;
    darkone.system.sops.isolated = lib.mkDefault true;
  };
}
