# DNF matrix: MatrixRTC calls (LiveKit). Doc: `../matrix.nix` header.

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  ...
}:
let
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;
  inherit (cfg.shared) params livekitJwtUrl;
  livekitPort = dnfConfig.network.ports.livekit;
  livekitJwtPort = dnfConfig.network.ports.livekitJwt;

  # SFU websocket, stripped of its prefix (`handle_path`): livekit-client
  # appends `/rtc` to the url the JWT service hands back.
  livekitSfuUrl = "wss://${params.fqdn}/livekit/sfu";

  # Names the shared secret inside livekit's keyfile. Only ever compared
  # between the two daemons, never exposed to a client.
  livekitApiKey = "dnf-matrixrtc";
in
{
  config = lib.mkIf (cfg.enable && cfg.matrixRtc.enable) {

    # One shared secret for both daemons: the SFU validates the JWTs the
    # authorization service signs with it. LiveKit wants a `<key>: <secret>`
    # map, hence the template rather than a bare sops secret.
    sops.secrets.livekit-secret = { };
    sops.templates.livekit-keyfile = {
      content = "${livekitApiKey}: ${config.sops.placeholder.livekit-secret}";
      restartUnits = [
        "livekit.service"
        "lk-jwt-service.service"
      ];
    };

    services.livekit = {
      enable = true;
      keyFile = config.sops.templates.livekit-keyfile.path;

      # Would publish the SFU's HTTP port, which only caddy may reach; the
      # media ports it does not cover are opened below.
      openFirewall = false;

      settings = {
        port = livekitPort;
        rtc = {

          # Media ports, one per participant. Deliberately clear of both
          # coturn's relay range and the kernel ephemeral range
          # (cf. config/network.nix).
          port_range_start = dnfConfig.network.ports.livekitRtcUdpStart;
          port_range_end = dnfConfig.network.ports.livekitRtcUdpEnd;
          tcp_port = dnfConfig.network.ports.livekitRtcTcp;

          # The host holds its public address directly, so candidates need no
          # STUN discovery. Behind NAT this must become true (cf. header).
          use_external_ip = false;

          # The tailnet address is a candidate no remote client can use:
          # advertising it only costs every call an ICE timeout.
          ips.excludes = [ dnfLib.constants.tailnetIpv4Cidr ];
        };

        # Rooms are created by the authorization service, which alone knows
        # whether the matrix user may open one. Left on (the default), any
        # JWT-less join would conjure a room.
        room.auto_create = false;
      };
    };

    services.lk-jwt-service = {
      enable = true;
      port = livekitJwtPort;
      keyFile = config.sops.templates.livekit-keyfile.path;

      # Handed to clients as-is, so it must be the public websocket url and
      # not the loopback the SFU actually binds.
      livekitUrl = livekitSfuUrl;
    };

    # Who may have a livekit room created for them. The service defaults to
    # `*`: any federated server could then spend our SFU's resources. Remote
    # users keep joining rooms a local user opened.
    systemd.services.lk-jwt-service.environment.LIVEKIT_FULL_ACCESS_HOMESERVERS =
      srv.settings.server_name;

    # Media never goes through the reverse proxy: clients reach these
    # directly. TCP is the fallback for networks that drop UDP.
    networking.firewall = {
      allowedTCPPorts = [ dnfConfig.network.ports.livekitRtcTcp ];
      allowedUDPPortRanges = [
        {
          from = dnfConfig.network.ports.livekitRtcUdpStart;
          to = dnfConfig.network.ports.livekitRtcUdpEnd;
        }
      ];
    };

    # Transport discovery (MSC4143). Recent clients read it here first and
    # only fall back to the well-known, which is filled in too.
    services.matrix-synapse.settings = {
      experimental_features.msc4143_enabled = true;
      matrix_rtc.transports = [
        {
          type = "livekit";
          livekit_service_url = livekitJwtUrl;
        }
      ];
    };
  };
}
