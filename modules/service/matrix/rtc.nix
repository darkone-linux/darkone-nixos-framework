# DNF matrix: audio/video calls, MatrixRTC backend (LiveKit SFU + JWT service).
#
# Two stacks coexist, because no single one covers every client:
#
# - Legacy 1:1 WebRTC, negotiated over synapse and relayed by coturn
#   (`darkone.service.turn`). The only thing Element Classic speaks.
# - MatrixRTC (`matrixRtc.enable`): a LiveKit SFU plus its authorization
#   service, for group calls and for Element Call. Element X speaks *only*
#   this one and reports "call is not supported"
#   (`MISSING_MATRIX_RTC_TRANSPORT`) without it; Element Web/Desktop embed
#   Element Call too and gain group calls from it.
#
# Both are served from the matrix vhost, next to synapse and MAS: the SFU
# websocket on `/livekit/sfu`, the JWT service on `/livekit/jwt`. Clients
# discover it from `matrix_rtc.transports` (synapse, MSC4143) and, as a
# fallback for older ones, from `rtc_foci` in the well-known.
#
# Required sops secret: `livekit-secret` (`just configure-admin-host`),
# shared by the SFU and the JWT service.
#
# :::caution[Media ports must reach the host]
# Media does not go through the reverse proxy. The UDP range and the TCP
# fallback are opened on the public interface, so a NATed host needs them
# forwarded, and `rtc.use_external_ip` set (untested here: the HCS holds its
# public address directly).
# :::
#
# :::caution[Echo cancellation is not a server-side setting]
# `services.livekit.settings` is freeform: unknown keys reach the config
# file silently. LiveKit's `audio` section only tunes active speaker
# detection and RED redundancy; `echo_cancellation`, `noise_suppression`
# and `channels` do not exist there. They are `getUserMedia` constraints,
# owned by the client.
#
# No SFU setting can fix an echoing participant:
#
# - LiveKit forwards Opus without ever decoding it.
# - AEC needs the local speaker reference, which never leaves the device.
# - Element Call encrypts media end to end, so the SFU cannot read it.
#
# The remedy is device-side: a headset, or Element Call's own audio
# processing toggles. Beware the diagnosis trap: a handset whose hardware
# AEC advertises itself but does nothing echoes for everyone *else*, never
# for its own user.
# :::

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
