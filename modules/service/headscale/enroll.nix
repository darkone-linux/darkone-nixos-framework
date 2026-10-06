# DNF headscale: `dnf-tailnet-enroll`, the root side of `just tailnet-enroll`.
#
# Single-use keys tagged from the declared topology; the enrolled node gets
# its declared name and tags.

{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  inherit (cfg.shared) auditSpec;

  # Root side of `just tailnet-enroll`, reached through sudo. Tags and names
  # come from the declared topology only, never from the caller.
  enrollCmd = "dnf-tailnet-enroll";
  enrollBin = "/run/current-system/sw/bin/${enrollCmd}";
  enrollScript = pkgs.writeShellScriptBin enrollCmd ''
    set -euo pipefail
    hs() { ${srv.package}/bin/headscale --config /etc/headscale/config.yaml "$@" </dev/null; }
    jq=${pkgs.jq}/bin/jq
    die() {
      echo "${enrollCmd}: $*" >&2
      exit 1
    }
    usage="usage: ${enrollCmd} status <host> [nodeKey] | key <host> | adopt <host> <nodeKey>"

    cmd=''${1:-}
    host=''${2:-}
    nodeKey=''${3:-}
    [[ $host =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$usage"
    declared=$($jq -c --arg h "$host" 'first(.nodes[] | select(.name == $h) | {tags, ipv4}) // null' ${auditSpec})

    # Reduced at once: the raw list carries pre-auth keys in clear.
    nodes() {
      hs nodes list -o json | $jq -c '[.[] | {
        id,
        name: .given_name,
        tags: ((.tags // []) | sort),
        ipv4: ([.ip_addresses[]? | select(test("^[0-9.]+$"))] | first),
        online: (.online // false),
        nodeKey: .node_key
      }]'
    }
    byKey() { $jq -c --arg k "$nodeKey" 'first(.[] | select($k != "" and .nodeKey == $k)) // null'; }

    case "$cmd" in

      # Declared identity, and the node holding the host's current node key.
      status)
        $jq -n -c --argjson d "$declared" --argjson n "$(nodes | byKey)" \
          '{declared: $d, node: (if $n == null then null else $n | del(.nodeKey) end)}'
        ;;

      # Single-use and short-lived: worthless once the host has registered.
      key)
        [ "$declared" != null ] || die "$host: no declared tailnet identity"
        tags=$($jq -r '.tags | join(",")' <<<"$declared")
        hs preauthkeys create --tags "$tags" --expiration 10m -o json | $jq -er '.key'
        ;;

      # Declared tags and name on the host's node. One declared host is one
      # machine: an offline homonym is the registration a reinstall left.
      adopt)
        [ "$declared" != null ] || die "$host: no declared tailnet identity"
        list=$(nodes)
        node=$(byKey <<<"$list")
        [ "$node" != null ] || die "$host: no node holds key $nodeKey"
        id=$($jq -r .id <<<"$node")
        want=$($jq -c .tags <<<"$declared")
        if [ "$($jq -c .tags <<<"$node")" != "$want" ]; then
          hs nodes tag -i "$id" --tags "$($jq -r 'join(",")' <<<"$want")" >/dev/null
          echo "node $id: tags set to $want" >&2
        fi
        if [ "$($jq -r .name <<<"$node")" != "$host" ]; then
          for stale in $($jq -r --arg h "$host" --argjson id "$id" \
            '.[] | select(.name == $h and .id != $id) | "\(.id):\(.online)"' <<<"$list"); do
            [ "''${stale#*:}" = false ] || die "node ''${stale%:*} named $host is online, not deleting it"
            hs nodes delete -i "''${stale%:*}" --force >/dev/null
            echo "node ''${stale%:*}: stale registration of $host deleted" >&2
          done
          hs nodes rename -i "$id" "$host" >/dev/null
          echo "node $id: renamed to $host" >&2
        fi
        nodes | $jq -c --argjson id "$id" 'first(.[] | select(.id == $id)) | del(.nodeKey)'

        # Its tailnet IP joins the unbound view now, not at the next timer run.
        ${pkgs.systemd}/bin/systemctl start --no-block unbound-tailnet-view.service || true
        ;;
      *) die "$usage" ;;
    esac
  '';
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ enrollScript ];

    # For the deploy user. NOLOG_OUTPUT: the minted key is printed, kept out
    # of the R39 I/O logs.
    security.sudo.extraRules = [
      {
        users = [ "nix" ];
        runAs = "root";
        commands = [
          {
            command = enrollBin;
            options = [
              "NOPASSWD"
              "NOLOG_INPUT"
              "NOLOG_OUTPUT"
            ];
          }
        ];
      }
    ];
    darkone.security.sudo.allowedRootRules = [ enrollBin ];
  };
}
