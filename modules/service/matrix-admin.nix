# Matrix administration UI (Ketesa, formerly synapse-admin) for the local server.
#
# Static SPA, no backend: the browser talks straight to synapse's admin API and
# to MAS's, so the whole service is a Caddy `file_server` over a store path.
#
# The DNF service name is deliberately not the package name. The UI is
# swappable (Element Admin, a later fork) without touching the URL, the DNS
# record or `etc/config.yaml`.
#
# Reachable from the LAN and the tailnet only (`proxy.isInternal`): the bundle
# holds no secret, but an admin login page has no reason to face the Internet.
#
# :::caution[Two server-side prerequisites]
# - MAS must serve its `adminapi` resource — done by `matrix.nix` as soon as
#   `mas.enable`. Without it login succeeds, then every MAS panel (sessions,
#   registration tokens, emails) fails.
# - The administrator account needs `can_request_admin`:
#   `sudo dnf-mas manage promote-admin <login>`.
# :::

{
  lib,
  dnfLib,
  config,
  network,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.matrix-admin;

  # The client-facing vhost, not synapse's port: `wellKnownDiscovery` resolves
  # it the same way a hand-typed url would be.
  localMatrixServer = "https://matrix.${network.domain}";

  # `asManagedUsers` patterns are matched as written, so the domain dots must
  # be escaped or they would match any single character.
  domainRe = lib.replaceStrings [ "." ] [ "\\." ] network.domain;

  defaultParams = {
    description = "Matrix accounts administration";
  };

  adminUi = pkgs.ketesa.withConfig {

    # A single url removes the homeserver field from the login page entirely.
    restrictBaseUrl = localMatrixServer;

    # Appservice-owned accounts: every mautrix bot (`<bridge>bot`) and every
    # puppet it spawns (`<bridge>_<remote id>`). Marked read-mostly, so a
    # misclick cannot deactivate a live bridge; names, avatars stay editable.
    asManagedUsers = [
      "^@[a-z]+bot:${domainRe}$"
      "^@(whatsapp|signal|telegram|messenger|discord)_.+:${domainRe}$"
    ];
  };
in
{
  options = {
    darkone.service.matrix-admin.enable = lib.mkEnableOption "Enable the local matrix administration UI";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.matrix-admin = {
        inherit defaultParams;

        # Admin tool: no tile for the users who cannot log into it anyway.
        displayOnHomepage = false;

        proxy = {
          enable = true;
          hasReverseProxy = false;

          # LAN + tailnet only. The scope `urn:mas:admin` is what actually
          # guards the data; this only keeps the login page off the Internet.
          isInternal = true;
          extraConfig = ''
            root * /etc/matrix-admin
            file_server
          '';
        };
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "matrix-admin";

      # Get and expose the admin UI sources
      environment.etc."matrix-admin".source = adminUi;
    })
  ];
}
