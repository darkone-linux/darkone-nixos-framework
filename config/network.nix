# Global DNF network configuration.
#
# Framework-wide registry of internal service ports: the single source of truth
# so a module never hardcodes a port twice and two co-located services never
# silently collide. Modules read a value via `dnfConfig.network.ports.<key>`.
#
# :::note[Conventions]
# - Key naming: `<service>[Usage]` — the `ports.` prefix already says "port", so
#   the key says *what for*. A bare `<service>` is the service's main port.
# - `ports.*` are DNF-fixed values; `ports.reserved` lists ports DNF inherits
#   from an upstream module default (`config.services.<x>.port`) and therefore
#   only needs to avoid, not own.
# - Sorted by value. `tests/unit/config/network_test.nix` enforces global
#   uniqueness across every `ports.*` value and `ports.reserved`.
# :::

{
  ports = {

    # NFSv4 home shares. modules/service/nfs.nix
    nfs = 2049;

    # Immich HTTP API. modules/service/immich.nix
    immich = 2283;

    # Forgejo HTTP server. modules/service/forgejo.nix
    forgejo = 3000;

    # Outline wiki HTTP. modules/service/outline.nix
    outline = 3003;

    # AdGuard Home web UI. modules/service/adguardhome.nix
    adguardhome = 3083;

    # Loki HTTP API. modules/service/loki.nix
    loki = 3100;

    # Grafana web UI. modules/service/monitoring.nix
    grafana = 3222;

    # Garage S3 API on the internal IP. modules/service/garage.nix
    garage = 3900;

    # Garage inter-node RPC. modules/service/garage.nix
    garageRpc = 3901;

    # Docs nginx (S3-backed static site). modules/service/docs.nix
    docs = 4445;

    # Harmonia Nix binary cache (HTTP). modules/service/harmonia.nix
    harmonia = 5000;

    # dnsmasq DNS port when AdGuard Home owns :53. modules/service/dnsmasq.nix
    dnsmasqAlt = 5353;

    # Immich Redis backend (localhost). modules/service/immich.nix
    immichRedis = 6379;

    # Matrix Synapse client/federation listener. modules/service/matrix.nix
    matrix = 8008;

    # Homepage dashboard. modules/service/homepage.nix
    homepage = 8082;

    # Nextcloud internal nginx vhost. modules/service/nextcloud.nix
    nextcloud = 8089;

    # Jellyfin HTTP (jellyfin's fixed default). modules/service/jellyfin.nix
    jellyfin = 8096;

    # Home Assistant HTTP (upstream default). modules/service/home-assistant.nix
    homeAssistant = 8123;

    # Vaultwarden Rocket HTTP. modules/service/vaultwarden.nix
    vaultwarden = 8222;

    # SearXNG HTTP. modules/service/searx.nix
    searx = 8283;

    # Kanidm HTTPS (IdM, reverse-proxy target). modules/service/idm.nix
    kanidm = 8443;

    # Kanidm replication listener (mTLS pull, HCS supplier <-> replicas).
    # modules/service/idm.nix
    kanidmReplication = 8444;

    # Nix binary-cache proxy (nginx). modules/service/nix-cache.nix
    nixCache = 8502;

    # Restic REST server. modules/service/restic.nix
    restic = 8888;

    # MinIO S3 API on the internal IP. modules/service/minio.nix
    minio = 9000;

    # MinIO console web UI. modules/service/minio.nix
    minioConsole = 9001;

    # Mealie HTTP (pinned off upstream :9000 to avoid the minio clash).
    # modules/service/mealie.nix
    mealie = 9002;

    # Prometheus Alertmanager web/API. modules/service/monitoring.nix
    alertmanager = 9093;

    # Loki gRPC listener. modules/service/loki.nix
    lokiGrpc = 9096;

    # matrix-alertmanager webhook bot (loopback). modules/service/monitoring.nix
    matrixAlertReceiver = 9099;

    # Prometheus node exporter. modules/service/monitoring.nix
    nodeExporter = 9100;

    # Prometheus blackbox exporter (network probes). modules/service/monitoring.nix
    blackboxExporter = 9115;

    # Synapse Prometheus metrics listener. modules/service/matrix.nix
    matrixMetrics = 9148;

    # Prometheus postfix exporter (mail queue). modules/service/postfix.nix
    postfixExporter = 9154;

    # Prometheus smartctl exporter (disk SMART health). modules/service/monitoring.nix
    smartctlExporter = 9633;

    # Open WebUI (AI front-end, reverse-proxy target). modules/service/ai.nix
    ai = 9758;

    # Mautrix-Telegram appservice. modules/service/matrix.nix
    matrixTelegram = 29317;

    # Mautrix-Discord appservice (upstream default restated because the
    # module's appservice option does not merge). modules/service/matrix.nix
    matrixDiscord = 29334;

    # Ports owned by an upstream module (inherited via `config.services.<x>.port`):
    # DNF does not bind them, but a new `ports.*` value must steer clear.
    # Format: value # service -- source module.
    reserved = [
      2317 # geneweb -- modules/service/geneweb.nix
      3478 # coturn STUN/TURN -- modules/service/turn.nix
      5349 # coturn TURN/TLS -- modules/service/turn.nix
      8080 # headscale -- modules/service/headscale.nix
      8086 # oxicloud -- modules/service/oxicloud.nix
      9090 # prometheus -- modules/service/monitoring.nix
      11434 # ollama -- modules/service/ai.nix
      29318 # mautrix-whatsapp appservice -- modules/service/matrix.nix
      29319 # mautrix-meta appservice -- modules/service/matrix.nix
      29328 # mautrix-signal appservice -- modules/service/matrix.nix
    ];
  };
}
