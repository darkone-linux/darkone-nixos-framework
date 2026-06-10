# DNF — homepage section rendering
#
# Turns resolved service entries into homepage dashboard sections, with a
# colour-coded marker classifying each as public/private and local/remote
# relative to the consuming host's zone. Pure and side-effect free.

{ lib, constants }: {

  # Build the homepage section entries for a list of services. Classifies
  # each entry as public/private and local/remote relative to the current
  # zone, prefixing the description with a colour-coded marker.
  #
  # `currentZoneName` is the zone the consuming host sits in (typically
  # `zone.name` in the caller's scope). Each `srv` must expose
  # `params.{title,description,zone,host,global,href,icon}` and a
  # `displayOnHomepage` flag.
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
          inherit (srv.params) href;
          inherit (srv.params) icon;
        };
      }
    ) services;
}
