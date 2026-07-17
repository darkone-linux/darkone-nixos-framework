# Global DNF alerting configuration.
#
# Framework-wide denylist of systemd units the generic `SystemdUnitFailed` rule
# must not report: units whose failure is known, expected and not actionable, so
# they would otherwise page a human forever. Read by
# `modules/service/prometheus.nix` via `dnfConfig.alerts.ignoredUnits` and passed
# down to `dnfLib.mkAlertRuleGroups`.
#
# :::note[Conventions]
# - Full unit name including its suffix (`<name>.service`), sorted alphabetically.
# - Each entry carries a comment: why it fails, and what makes it removable.
# - Last resort: an ignored unit is invisible to alerting on *every* node. Fix or
#   disable the unit first; ignore only what neither is possible for.
# :::

{
  ignoredUnits = [

    # Legacy python bridge: broken since nixpkgs' setuptools >= 81, which drops
    # `pkg_resources` (imported by the 0.15.3 bridge -> ModuleNotFoundError at
    # runtime). Left failed on hosts that enabled it before the default flip.
    # Drop this entry once the Go bridgev2 telegram bridge replaces it.
    # modules/service/matrix.nix
    "mautrix-telegram.service"
  ];
}
