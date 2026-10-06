# DNF idm: Kanidm replication. Doc: `../idm.nix` header.

{
  lib,
  dnfLib,
  dnfConfig,
  network,
  host,
  zone,
  config,
  workDir,
  ...
}:
let
  inherit (lib)
    any
    filter
    filterAttrs
    hasAttrByPath
    listToAttrs
    mapAttrsToList
    mkIf
    optionalAttrs
    ;
  cfg = config.darkone.service.idm;
  isHcs = dnfLib.isHcs host zone network;

  # The HCS, or the only instance of a network without coordination.
  isMainReplica = isHcs || !network.coordination.enable;

  # A coordinated local-zone gateway is a read-only replica candidate.
  isZoneReplica =
    dnfLib.isGateway host zone && dnfLib.inLocalZone zone && network.coordination.enable;

  globalZone = dnfLib.constants.globalZone;
  replPort = dnfConfig.network.ports.kanidmReplication;
  hcsVpnIp = network.zones.${globalZone}.gateway.vpn.ipv4;
  mkReplOrigin = ip: "repl://${ip}:${toString replPort}";
  hcsOrigin = mkReplOrigin hcsVpnIp;

  # Replication identity certificates are PUBLIC and fetched out-of-band by
  # `just idm-sync-certs` into the consumer workspace. A missing file (phase 1,
  # before the peer has generated its identity) simply omits the partner block
  # so the node still boots and emits its own certificate. Newlines/spaces are
  # stripped: the TOML value must be the bare single-line certificate.
  readReplCert =
    hostname:
    let
      f = workDir + "/usr/secrets/replication/${hostname}.pem";
    in
    if builtins.pathExists f then
      builtins.replaceStrings [ "\n" "\r" " " ] [ "" "" "" ] (builtins.readFile f)
    else
      "";

  # HCS (supplier) certificate. Public, synced out-of-band by `just idm-sync-certs`
  # into usr/secrets/replication/. Empty until step 1's certificates are gathered.
  hcsReplCert = readReplCert network.coordination.hostname;

  # Where idm runs on the network. `network.services` mirrors the per-host service
  # declarations (config.yaml -> var/generated/), and the `idm` key drives
  # `darkone.service.idm.enable` (lib/service-activation.nix), so this is the
  # authoritative cross-host view of "which nodes run idm".
  idmInstances = filter (s: s.name == "idm") network.services;

  # idm declared on the HCS itself.
  idmOnHcs = any (s: s.zone == globalZone && s.host == network.coordination.hostname) idmInstances;

  # Local-zone gateways that run idm = replication consumers (need a gateway VPN
  # IP to bind the pull origin). Keyed by zone name.
  replConsumerZones = filterAttrs (
    _: z:
    dnfLib.inLocalZone z
    && hasAttrByPath [ "gateway" "hostname" ] z
    && hasAttrByPath [ "gateway" "vpn" "ipv4" ] z
    && any (s: s.zone == z.name && s.host == z.gateway.hostname) idmInstances
  ) network.zones;

  # Replication engages when idm runs on the HCS *and* on >= 1 zone gateway of
  # a coordinated network; otherwise every binding below stays single-instance.
  replicationActive = network.coordination.enable && idmOnHcs && replConsumerZones != { };

  # This node takes part in replication: the HCS as supplier, an idm-running
  # local gateway as consumer.
  replEnabled = replicationActive && (isHcs || (isZoneReplica && replConsumerZones ? ${zone.name}));

  # A gateway consuming the HCS, in both bootstrap steps. NEVER provisioned:
  # the supplier overwrites its DB, and the provisioning probe needs the web
  # UI a WriteReplicaNoUI does not serve.
  isReplConsumer = replEnabled && isZoneReplica;

  # A consumer only switches to the read-only role once its HCS supplier cert is
  # synced (step 2). Until then it is a WriteReplicaNoUI that boots and emits its
  # own replication identity (step 1), but stays unprovisioned (empty DB) — it
  # only serves logins once replication is established in step 2.
  isRoReplica = isReplConsumer && hcsReplCert != "";

  # Supplier side (HCS): one `allow-pull` block per zone-gateway consumer whose
  # certificate has already been synced.
  replSupplierBlocks = listToAttrs (
    filter (e: e != null) (
      mapAttrsToList (
        _: z:
        let
          cert = readReplCert z.gateway.hostname;
        in
        if cert == "" then
          null
        else
          {
            name = mkReplOrigin z.gateway.vpn.ipv4;
            value = {
              type = "allow-pull";
              consumer_cert = cert;
            };
          }
      ) replConsumerZones
    )
  );

  # Consumer side (zone gateway): a single `pull` block toward the HCS supplier.
  replConsumerBlocks = optionalAttrs (hcsReplCert != "") {
    ${hcsOrigin} = {
      type = "pull";
      supplier_cert = hcsReplCert;
      automatic_refresh = true;
    };
  };

  # Effective `replication` settings for this node (only used when replEnabled).
  replSettings = {
    origin = if isHcs then hcsOrigin else mkReplOrigin zone.gateway.vpn.ipv4;
    bindaddress = "${if isHcs then hcsVpnIp else zone.gateway.vpn.ipv4}:${toString replPort}";
  }
  // (if isHcs then replSupplierBlocks else replConsumerBlocks);
in
{

  # Replication facts read by `../idm.nix` and `provision.nix`.
  options.darkone.service.idm.replication = lib.mkOption {
    type = lib.types.raw;
    internal = true;
    readOnly = true;
    default = { inherit isMainReplica isReplConsumer; };
    defaultText = "computed";
    description = "Replication facts of this node.";
  };

  config = mkIf cfg.enable {

    # Consumers (zone gateways) initiate the pull connection towards the HCS,
    # so only the supplier needs the replication port reachable, and only over
    # the tailnet. Merges with the port 53 rule set by `headscale/dns.nix`.
    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = mkIf (
      replEnabled && isHcs
    ) [ replPort ];

    services.kanidm.server.settings = {

      # Single instance: WriteReplica where main, else WriteReplicaNoUI.
      # Replicated: the HCS supplies; a gateway is WriteReplicaNoUI until its
      # HCS supplier cert is synced, then ReadOnlyReplica.
      role =
        if !replEnabled then
          (if isMainReplica then "WriteReplica" else "WriteReplicaNoUI")
        else if isHcs then
          "WriteReplica"
        else if isRoReplica then
          "ReadOnlyReplica"
        else
          "WriteReplicaNoUI";

      # `origin`/`bindaddress` make the node generate its replication identity
      # at first boot; partner blocks appear once the peer certificates are
      # synced (`readReplCert`).
      replication = mkIf replEnabled replSettings;
    };
  };
}
