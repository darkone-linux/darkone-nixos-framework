# Global DNF network configuration.
#
# Central, framework-wide registry of service ports. Single source of truth so
# modules never hardcode a port number twice. Extend `ports` as services that
# need a well-known port are added.

{
  ports = {

    # Kanidm replication listener (mTLS pull protocol between the HCS supplier
    # and the zone-gateway read-only replicas). See `modules/service/idm.nix`.
    kanidmReplPort = 8444;
  };
}
