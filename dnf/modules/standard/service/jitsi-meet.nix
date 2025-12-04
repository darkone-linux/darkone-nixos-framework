# A full-configured jitsi-meet service.

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.jitsi-meet;
  defaultParams = {
    title = "Jitsi Meet";
    description = "Video Conferencing";
  };
  params = dnfLib.extractServiceParams host network "jitsi-meet" defaultParams;
in
{
  options = {
    darkone.service.jitsi-meet.enable = lib.mkEnableOption "Enable local jitsi-meet service";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.jitsi-meet = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/jitsi-meet" ];
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.jitsi-meet.enable = true;
      };

      # TMP?
      nixpkgs.config.permittedInsecurePackages = [ "jitsi-meet-1.0.8792" ];

      # Forgejo main service
      services.jitsi-meet = {
        enable = true;
        nginx.enable = false;
        caddy.enable = true;
        hostName = params.fqdn;
        config = {
          enableWelcomePage = false;
          defaultLang = zone.lang;
          prejoinPageEnabled = true;
          disableModeratorIndicator = true;
        };
        interfaceConfig = {
          SHOW_JITSI_WATERMARK = false;
          SHOW_WATERMARK_FOR_GUESTS = false;
        };
      };
    })
  ];
}
