# SuperTuxKart with configurations to play in local network.
#
# :::tip
# To use in conjonction with homemanager games module!
# :::
#
# :::note[Shared tracks]
# The tracks share itself lives in `service/stk.nix`. `enableNfsClient` and
# `nfsServer` are the only knobs a host needs: they wire
# `darkone.service.stk.{enableClient,serverName}` so a machine configuration
# never has to name two modules for one game.
# :::
#
# :::tip[Playing across zones]
# Game and discovery ports accept every zone prefix and the tailnet. Broadcast
# discovery stays inside the zone: from another zone, join with "Enter server
# address" (server IP, port 2759).
# :::
#
# :::caution[Fleet-scoped firewall]
# Sources are matched on fleet prefixes, never on an interface: a STK host that
# also holds a WAN address does not publish the game there.
# :::

{
  lib,
  config,
  dnfLib,
  zone,
  host,
  network,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.supertuxkart;

  # The global zone carries no prefix: nothing to anchor a source match on.
  inLocalZone = dnfLib.inLocalZone zone;
  zoneCidr = lib.optionalString inLocalZone "${zone.networkIp}/${toString zone.prefixLength}";

  # Other zones arrive through the gateways with their source kept
  # (`--snat-subnet-routes=false`); roaming hosts with their tailnet address.
  fleetCidrs =
    lib.mapAttrsToList (_: z: "${z.networkIp}/${toString z.prefixLength}") (
      lib.filterAttrs (_: dnfLib.inLocalZone) network.zones
    )
    ++ lib.optional network.coordination.enable dnfLib.constants.tailnetIpv4Cidr;
in
{
  options = {
    darkone.graphic.supertuxkart.enable = lib.mkEnableOption "SuperTuxKart + firewall config";
    darkone.graphic.supertuxkart.enableNfsClient = lib.mkEnableOption "Mount the shared tracks of the zone's `stk` server";
    darkone.graphic.supertuxkart.nfsServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hostname serving the tracks, default is the zone's `stk` service host";
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = inLocalZone;
        message = "darkone.graphic.supertuxkart on ${host.hostname}: LAN game, unusable in the global zone (no prefix to scope its firewall rules on).";
      }
    ];

    # STK package
    environment.systemPackages = with pkgs; [ supertuxkart ];

    # Facade over the share. Only ever asserts the positive, so the service's
    # own defaults — false, and the zone's `stk` host — still apply, and a
    # direct `darkone.service.stk.*` definition does not collide with it.
    darkone.service.stk = {
      enableClient = lib.mkIf cfg.enableNfsClient true;
      serverName = lib.mkIf (cfg.nfsServer != null) cfg.nfsServer;
    };

    # Open ports & accept broadcasts (local servers discovery)
    networking.firewall = {
      enable = true;

      # No `allowedUDPPorts`: without `iifname` nor source match, every host leg
      # would get the game. 2757 (discovery) and 2759 (game) from the fleet;
      # the ephemeral range from the zone only: broadcast discovery answers,
      # which conntrack cannot relate, never cross a gateway.
      extraInputRules = lib.optionalString inLocalZone ''
        ip saddr { ${lib.concatStringsSep ", " fleetCidrs} } udp dport { 2757, 2759 } accept
        ip saddr ${zoneCidr} udp dport 32768-60999 accept
      '';
    };
  };
}
