# DNF headscale: `headscale-audit`, live tailnet against the declared one.
#
# Every 15 min, compares the live nodes with the declared topology: metrics
# for the `dnf-headscale-<zone>` alerts, details in its journal. It never tags
# nor deletes.

{
  lib,
  dnfLib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  inherit (cfg.shared) auditSpec idmUrl;
  textfileDir = dnfLib.constants.textfileCollectorDir;

  # Checks on the reduced node list; `$mode` selects metrics or journal lines.
  # Label values are DNS names and logins: anything else is flattened to `_`.
  auditJq = pkgs.writeText "headscale-audit.jq" ''
    def lv: tostring | gsub("[^A-Za-z0-9_.@-]"; "_");
    def flag(b): if b then 1 else 0 end;

    $spec[0] as $s
    | . as $nodes
    | ($nodes | map(select(.tags != []))) as $tagged
    | ($nodes | map(select(.tags == []))) as $personal
    | [
        ($s.nodes[] as $e
          | ($nodes | map(select(.name == $e.name)) | first) as $n
          | {
              node: $e.name,
              missing: ($n == null and $e.required),
              tag_mismatch: ($n != null and $n.tags != $e.tags),
              ip_drift: ($n != null and $e.ipv4 != null and $n.ipv4 != $e.ipv4)
            }),
        ($s.adminDevices | to_entries[]
          | .value as $ip
          | {
              node: .key,
              missing: false,
              tag_mismatch: false,
              ip_drift: ($personal | map(select(.ipv4 == $ip)) | length == 0)
            })
      ] as $checks
    | (
        [$tagged[] | select((.name | IN($s.nodes[].name)) | not)]
        + [$personal[] | select((.user | IN($s.users[])) | not)]
      ) as $unexpected
    | if $mode == "metrics" then
        ($checks[]
          | "dnf_headscale_node_missing{node=\"\(.node | lv)\"} \(flag(.missing))",
            "dnf_headscale_node_tag_mismatch{node=\"\(.node | lv)\"} \(flag(.tag_mismatch))",
            "dnf_headscale_node_ip_drift{node=\"\(.node | lv)\"} \(flag(.ip_drift))"),
        ($unexpected[]
          | "dnf_headscale_unexpected_node{node=\"\(.name | lv)\",user=\"\(.user | lv)\"} 1"),
        ($personal[] | select(.expiry != null)
          | "dnf_headscale_node_expiry_timestamp_seconds{node=\"\(.name | lv)\",user=\"\(.user | lv)\"} \(.expiry)")
      else
        ($checks[] | select(.missing) | "missing: \(.node)"),
        ($checks[] | select(.tag_mismatch) | "tag mismatch: \(.node)"),
        ($checks[] | select(.ip_drift) | "ip drift: \(.node)"),
        ($unexpected[] | "unexpected: \(.name) (user \(.user))")
      end
  '';

  auditScript = pkgs.writeShellScript "headscale-audit" ''
    set -euo pipefail
    hs() { ${srv.package}/bin/headscale --config /etc/headscale/config.yaml "$@" </dev/null; }
    jq=${pkgs.jq}/bin/jq

    # Reduce at once: the raw list carries pre-auth keys in clear, never printed.
    nodes=$(hs nodes list -o json | $jq -c '[.[] | {
      name: .given_name,
      user: .user.name,
      tags: ((.tags // []) | sort),
      ipv4: ([.ip_addresses[]? | select(test("^[0-9.]+$"))] | first),
      expiry: (.expiry.seconds // null)
    }]')
    audit() { $jq -r --slurpfile spec ${auditSpec} --arg mode "$1" -f ${auditJq} <<<"$nodes"; }
    audit findings

    policy=1
    if ! hs policy check -f /etc/headscale/policy.hujson >/dev/null 2>&1; then
      echo "policy: fails headscale policy check"
      policy=0
    elif [ "$(hs policy get | $jq -S -c .)" != "$($jq -S -c . /etc/headscale/policy.hujson)" ]; then
      echo "policy: served policy differs from /etc/headscale/policy.hujson"
      policy=0
    fi
    ${lib.optionalString (idmUrl != null) ''

      # headscale never retries OIDC: a fallback warning in this run's journal holds.
      oidc=1
      run=$(${pkgs.systemd}/bin/systemctl show -p InvocationID --value headscale.service)
      hits=$(${pkgs.systemd}/bin/journalctl -q -o cat _SYSTEMD_INVOCATION_ID="$run" \
        | ${pkgs.gnugrep}/bin/grep -c 'falling back to CLI based authentication' || true)
      if [ "$hits" != 0 ]; then
        echo "oidc: fell back to CLI registration at startup"
        oidc=0
      fi
    ''}

    # Best-effort metrics: only supervised hosts have the collector dir.
    [ -d ${textfileDir} ] || exit 0
    tmp=$(${pkgs.coreutils}/bin/mktemp ${textfileDir}/.headscale.XXXXXX)
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
    {
      audit metrics
      echo "dnf_headscale_policy_valid $policy"
      ${lib.optionalString (idmUrl != null) ''echo "dnf_headscale_oidc_available $oidc"''}
      echo "dnf_headscale_audit_last_success_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
    } > "$tmp"

    # mktemp creates 0600; node_exporter reads as a non-root user.
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" ${textfileDir}/headscale.prom
  '';
in
{
  config = lib.mkIf cfg.enable {

    # Read-only: reports drift as metrics and journal lines, fixes nothing.
    # Root keeps its capabilities: the gRPC socket is `headscale`-group only.
    systemd.services.headscale-audit = {
      description = "Compare headscale nodes with the declared tailnet";
      after = [ "headscale.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = auditScript;
        ProtectSystem = "strict";
        ReadWritePaths = [ "-${textfileDir}" ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.headscale-audit = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };
  };
}
