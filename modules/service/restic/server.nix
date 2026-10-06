# DNF restic: the REST server, storing every fleet host's repositories.
#
# One account per fleet host (`restic/<hostname>/rest-password`), checked
# against an htpasswd assembled at boot; `privateRepos` confines each host to
# its own `<hostname>/` prefix.
#
# :::caution[`listenAll` widens the bind, not the firewall]
# The server binds `params.ip`, i.e. the LAN address on a gateway. Clients
# reaching it from another zone over the tailnet need `listenAll = true`
# (bind `0.0.0.0`). The firewall stays the boundary: `lan0` gets the port from
# `getInternalInterfaceFwPath`, `tailscale0` is already a trusted interface on
# a gateway, and the WAN never opens it.
# :::
#

{
  config,
  lib,
  dnfLib,
  dnfConfig,
  zone,
  host,
  hosts,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.restic;
  inherit (cfg.shared) params;
  srvPort = dnfConfig.network.ports.restic;

  # Fleet hosts deduplicated by hostname: one REST account per hostname.
  serverHosts = lib.foldl' (
    acc: h: if lib.any (x: x.hostname == h.hostname) acc then acc else acc ++ [ h ]
  ) [ ] hosts;

  # Runtime htpasswd assembly: one bcrypt entry per fleet hostname.
  htpasswdFile = "/run/restic-rest/htpasswd";
  htpasswdLines = lib.concatStringsSep "\n" (
    lib.imap0 (
      idx: h:
      let
        pw = config.sops.secrets."restic/${h.hostname}/rest-password".path;
        flag = if idx == 0 then "-bBc" else "-bB";
      in
      ''${pkgs.apacheHttpd}/bin/htpasswd ${flag} "${htpasswdFile}" "${h.hostname}" "$(${pkgs.coreutils}/bin/cat ${pw})"''
    ) serverHosts
  );
in
{
  config = lib.mkIf (cfg.enable && cfg.enableServer) {

    # Every fleet host's REST credential, to assemble the htpasswd.
    sops.secrets = lib.genAttrs (map (h: "restic/${h.hostname}/rest-password") serverHosts) (_: {
      mode = "0400";
      owner = "root";
    });

    # Server: assemble the multi-user htpasswd before the REST server starts.
    # Unsandboxed oneshot so the file exists before the server's namespace
    # binds it read-only (cf. ReadOnlyPaths in the upstream unit).
    systemd.services = {
      restic-rest-htpasswd = {
        description = "Assemble restic REST htpasswd from per-host secrets";
        wantedBy = [ "multi-user.target" ];
        before = [ "restic-rest-server.service" ];
        requiredBy = [ "restic-rest-server.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.coreutils}/bin/install -d -m 0750 -o restic -g restic /run/restic-rest
          ${htpasswdLines}
          ${pkgs.coreutils}/bin/chown restic:restic "${htpasswdFile}"
          ${pkgs.coreutils}/bin/chmod 0640 "${htpasswdFile}"
        '';
      };
      restic-rest-server = {
        after = [ "restic-rest-htpasswd.service" ];
        requires = [ "restic-rest-htpasswd.service" ];
      };
    };

    networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
      allowedTCPPorts = [ srvPort ];
    };

    services.restic.server = {
      enable = true;
      listenAddress = "${if cfg.listenAll then "0.0.0.0" else params.ip}:${toString srvPort}";
      dataDir = cfg.serverDataDir;
      htpasswd-file = htpasswdFile;

      # Per-host isolation: requires authenticated user == repo path prefix
      # (= hostname).
      privateRepos = true;
    };
  };
}
