# Matrix helpers
#
# Client/server discovery documents, shared by the two vhosts that serve them:
# the matrix service vhost (`modules/service/matrix.nix`) and the network apex
# domain (`modules/system/services.nix`). Both must answer the very same
# payload, so the JSON lives here rather than in two copies free to drift.

{ lib }: rec {

  # Caddyfile fragment answering the two matrix discovery documents.
  #
  # `rtcFociUrl` announces a MatrixRTC backend (MSC4143) to Element Call, which
  # every recent Element reads from here when the homeserver does not serve
  # `/org.matrix.msc4143/rtc/transports`. `null` omits the key entirely: a
  # deployment without LiveKit must advertise no focus at all, never an empty
  # list, which clients would read as "configured but unusable".
  #
  # Usage:
  #   mkMatrixWellKnown {
  #     domain = "example.org";
  #     rtcFociUrl = "https://matrix.example.org/livekit/jwt";
  #   }
  mkMatrixWellKnown =
    {
      domain,
      rtcFociUrl ? null,
    }:
    let
      client = {
        "m.homeserver".base_url = "https://matrix.${domain}";
      }
      // lib.optionalAttrs (rtcFociUrl != null) {
        "org.matrix.msc4143.rtc_foci" = [
          {
            type = "livekit";
            livekit_service_url = rtcFociUrl;
          }
        ];
      };
    in
    ''
      handle /.well-known/matrix/client {
        header Access-Control-Allow-Origin "*"
        header Content-Type "application/json"
        respond `${builtins.toJSON client}`
      }
      handle /.well-known/matrix/server {
        header Access-Control-Allow-Origin "*"
        header Content-Type "application/json"
        respond `{"m.server":"matrix.${domain}:443"}`
      }
    '';
}
