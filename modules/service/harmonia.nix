# Harmonia: local Nix binary cache server (serves this host's /nix/store).
#
# Exposes locally built / realised store paths over plain HTTP (port 5000),
# signed with the deployment-wide binary-cache key. Enable per host from
# `usr/config.yaml` (services.harmonia), like any other DNF service.
#
# :::note[How harmonia works with the nix-cache proxy]
# Harmonia is a *source* of packages, served **directly** to clients over the
# LAN (in-zone) or the tailnet (when flagged `global`). The per-zone `nix-cache`
# proxy is a separate concern: it caches the *public* binary cache
# (`cache.nixos.org`), never harmonia.
#
# Each local-zone host's substituters become, in priority order:
#
# - the harmonia instances of *its own zone* (highest priority, LAN), then
# - any harmonia flagged `global` (typically on the HCS, over the tailnet), then
# - the zone's `nix-cache` proxy (public cache).
#
# Other zones' non-global harmonia are never used. Harmonia's signature is
# passed through unchanged, so every host trusts the deployment-wide harmonia
# public key (`usr/secrets/harmonia.pub`). Transport is plain HTTP on the
# trusted LAN / VPN: integrity comes from the NAR signature, not from TLS.
# :::
#
# :::tip[Signing key provisioning]
# `just configure-admin-host` auto-generates the deployment-wide key pair when
# `usr/secrets/harmonia.pub` is missing: the public key is committed and the
# private key is injected into the sops secret `harmonia-secret-key`.
# :::
#
# :::note[Benign startup warning about sign-key permissions]
# `WARN harmonia_cache::tls: /run/credentials/harmonia.service/sign-key-0 has
# insecure permissions 0o440; recommend 0600` is a false positive: systemd
# exposes `LoadCredential` files as root-owned mode 0440 with an ACL that
# grants access to the service user only (systemd/systemd#29435); harmonia
# naively checks the chmod bits. Watch upstream though: harmonia already
# hard-rejects group-readable *TLS* keys at startup — if that policy ever
# extends to sign keys, this unit will break on upgrade.
# :::

{
  lib,
  config,
  dnfLib,
  dnfConfig,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.harmonia;
  harmoniaPort = dnfConfig.network.ports.harmonia;

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
          bind = "${host.ip}:${toString harmoniaPort}";
          workers = 4;

          # Lower value = higher priority than the public caches.
          priority = 30;
        };
      };

      # The socket binds a specific host IP, which may arrive late (DHCP lease,
      # even a fixed reservation, is configured after the socket unit starts) ->
      # bind fails with EADDRNOTAVAIL and the socket stays `failed` for good.
      # IP_FREEBIND lets it bind a not-yet-present address, closing the race.
      systemd.sockets.harmonia.socketConfig.FreeBind = true;

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      # Open the cache port on the internal interface so the zone's hosts can
      # reach it directly (clients use harmonia as a substituter). A
      # globally-exposed harmonia is also reached cross-zone over the tailnet,
      # so open the VPN interface as well.
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
