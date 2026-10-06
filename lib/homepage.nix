# DNF — homepage section rendering
#
# Turns resolved service entries into homepage dashboard sections. Pure and
# side-effect free.

{ lib, constants }: {

  # Homepage entries of `services`, descriptions suffixed with `(zone:host)`
  # and a marker: global 🟢 (in the global zone) or 🟡, private 🔵 (in
  # `currentZoneName`) or 🟠. Each `srv` carries `displayOnHomepage` and
  # `params.{title,description,zone,host,global,href,icon}`.
  mkHomepageSection =
    currentZoneName: services:
    map (
      srv:
      let
        pubPriv =
          if srv.params.global then
            (if srv.params.zone == constants.globalZone then "🟢" else "🟡")
          else
            (if srv.params.zone == currentZoneName then "🔵" else "🟠");
        mention = " (" + srv.params.zone + ":" + srv.params.host + ")";
      in
      {
        "${srv.params.title}" = lib.mkIf srv.displayOnHomepage {
          description = srv.params.description + mention + " " + pubPriv;
          inherit (srv.params) href icon;
        };
      }
    ) services;
}
