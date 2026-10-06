# Matrix helpers
#
# Client/server discovery documents, shared by the two vhosts that serve them:
# the matrix service vhost (`modules/service/matrix.nix`) and the network apex
# domain (`modules/system/services.nix`). Both must answer the very same
# payload, so the JSON lives here rather than in two copies free to drift.

{ lib }: rec {

  # Caddyfile fragment answering both matrix discovery documents.
  # `rtcFociUrl`: MatrixRTC focus (MSC4143) announced to Element Call. `null`
  # omits the key: an empty list reads as "configured but unusable".
  #
  #   mkMatrixWellKnown { domain = "example.org"; rtcFociUrl = null; }
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
