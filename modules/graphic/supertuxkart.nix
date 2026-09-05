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
# :::caution[Zone-scoped firewall]
# Game and discovery ports are accepted from the zone prefix only. A STK host
# that also holds a WAN or tailnet address does not publish the game there.
# :::

{
  lib,
  config,
  dnfLib,
  zone,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.supertuxkart;

  # The global zone carries no prefix: nothing to anchor a source match on.
  inLocalZone = dnfLib.inLocalZone zone;
  zoneCidr = lib.optionalString inLocalZone "${zone.networkIp}/${toString zone.prefixLength}";
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

      # No `allowedUDPPorts`: it emits no `iifname` and no source match, so the
      # game and its discovery range landed on every leg of the host. Three
      # rules, all anchored on the zone prefix:
      #
      # - 2757 covers the discovery broadcast as well as its unicast form;
      # - 2759 is the game server port;
      # - the ephemeral range receives the discovery answer, which conntrack
      #   cannot relate to a broadcast request.
      extraInputRules = lib.optionalString inLocalZone ''
        ip saddr ${zoneCidr} udp dport { 2757, 2759 } accept
        ip saddr ${zoneCidr} udp dport 32768-60999 accept
      '';
    };
  };
}
