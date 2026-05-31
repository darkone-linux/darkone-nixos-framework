# Harmonia: local Nix binary cache server (serves this host's /nix/store).
#
# Exposes locally built / realised store paths over plain HTTP (port 5000),
# signed with the deployment-wide binary-cache key. Enable per host from
# `usr/config.yaml` (services.harmonia), like any other DNF service.
#
# :::note[How Harmonia Services Work with NCPS]
# Harmonia is a *source* of packages; `ncps` is the per-zone caching proxy that
# clients actually talk to. Each zone's `ncps` server automatically adds, as
# upstreams:
#
# - the harmonia instances of *its own zone* (highest priority), then
# - any harmonia flagged `global` (typically on the HCS),
#
# and never the harmonia of *other* (non-global) zones. Clients fetch only
# through `ncps`; harmonia's signature is passed through unchanged, so every
# host trusts the deployment-wide harmonia public key
# (`usr/secrets/harmonia.pub`). Transport is plain HTTP on the trusted LAN /
# VPN: integrity comes from the NAR signature, not from TLS.
# :::
#
# :::tip[Signing key provisioning]
# `just configure-admin-host` auto-generates the deployment-wide key pair when
# `usr/secrets/harmonia.pub` is missing: the public key is committed and the
# private key is injected into the sops secret `harmonia-secret-key`.
# :::

{
  lib,
  config,
  dnfLib,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.harmonia;
  harmoniaPort = 5000;

  # This host's own harmonia service entry (if any), used to know whether it is
  # exposed globally, ie. reachable cross-zone over the tailnet.
  ownService = lib.findFirst (
    s: s.name == "harmonia" && s.host == host.hostname && s.zone == host.zone
  ) { } network.services;
  isGlobal = ownService.global or false;
in
{
  options = {
    darkone.service.harmonia.enable = lib.mkEnableOption "Enable a local Harmonia Nix binary cache server";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.harmonia = {
        displayOnHomepage = false;
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "harmonia";

      #------------------------------------------------------------------------
      # Sops (deployment-wide binary-cache signing key)
      #------------------------------------------------------------------------

      # The harmonia module loads signing keys via systemd LoadCredential: the
      # file is read as root and handed to the harmonia DynamicUser, so no
      # owner / group plumbing is required on the secret itself.
      sops.secrets.harmonia-secret-key = { };

      #------------------------------------------------------------------------
      # Harmonia cache server
      #------------------------------------------------------------------------

      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.sops.secrets.harmonia-secret-key.path ];
        settings = {
          bind = "[::]:${toString harmoniaPort}";

          # Lower value = higher priority than the public caches.
          priority = 30;
        };
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      # Open the cache port on the internal interface so the zone's ncps can
      # reach it. A globally-exposed harmonia is also reached cross-zone over
      # the tailnet, so open the VPN interface as well.
      networking.firewall = lib.mkMerge [
        (lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
          allowedTCPPorts = [ harmoniaPort ];
        })
        (lib.mkIf isGlobal {
          interfaces.${dnfLib.constants.vpnInterface}.allowedTCPPorts = [ harmoniaPort ];
        })
      ];
    })
  ];
}
