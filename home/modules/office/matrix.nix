# DNF office: Matrix desktop clients (Element, Fractal). Doc: `../office.nix` header.

{
  lib,
  config,
  pkgs,
  network,
  ...
}:
let
  inherit (lib) mkIf;
  cfg = config.darkone.home.office;
  inherit (cfg.shared) country hasMatrix;
  hasFractal = cfg.enableCommunication && hasMatrix;
  element = config.programs.element-desktop;
  localMatrixServer = "https://matrix.${network.domain}";
  idmUri = "https://idm.${network.domain}";
in
{
  config = mkIf cfg.enable {

    # Element for every office user of a Matrix network (opt out per user:
    # `programs.element-desktop.enable = false`), the only pre-configurable
    # client. Fractal lacks `m.login.sso` (native OIDC/MAS only, Synapse runs
    # legacy `oidc_providers`), a declarative config and a tray.

    # TODO: complete, share with modules/service/element.nix
    programs.element-desktop = mkIf hasMatrix {
      enable = lib.mkDefault true;
      settings = {
        default_server_config = {
          "m.homeserver" = {
            base_url = localMatrixServer;
            server_name = "${network.domain} matrix server";
          };
        };
        show_labs_settings = true;
        default_theme = "dark";
        default_federate = false;
        default_country_code = country;
        room_directory.servers = [ localMatrixServer ];
        brand = network.domain;
        sso_redirect_options = {
          immediate = true;
          on_welcome_page = true;
          on_login_page = true;
        };
        oidc_static_clients."${idmUri}/".client_id = "matrix-synapse";
        oidc_metadata = {
          client_uri = idmUri;
          logo_uri = idmUri + "/pkg/img/logo.svg";
        };
      };
    };

    # Auto-start Element (hidden, background-friendly client)
    systemd.user.services.element-desktop = mkIf (element.enable && cfg.enableElementAutoStart) {
      Unit = {
        Description = "Element Desktop (autostart)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.element-desktop}/bin/element-desktop --no-update --hidden";
        Restart = "on-failure";
      };
    };

    # Auto-start Fractal (opt-in: no --hidden, opens a visible window)
    systemd.user.services.fractal = mkIf (hasFractal && cfg.enableFractalAutoStart) {
      Unit = {
        Description = "Fractal (autostart)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.fractal}/bin/fractal";
        Restart = "on-failure";
      };
    };
  };
}
