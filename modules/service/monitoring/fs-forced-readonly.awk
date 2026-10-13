# Read-write mounts whose filesystem the kernel turned read-only.
#
# Input: /proc/<pid>/mountinfo. Output: node_exporter textfile, one series per
# affected mount, header only when all is well. Decision table pinned by
# tests/scenarios/scripts/fs-forced-readonly.nix.

# Prometheus label value: escape `\` and `"`. Space, tab, newline and backslash
# already come octal-encoded (`\040`) from the kernel.
function esc(s,    i, c, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"")
            out = out "\\"
        out = out c
    }
    return out
}

BEGIN {
    print "# HELP dnf_filesystem_forced_readonly Read-write mount whose filesystem the kernel turned read-only."
    print "# TYPE dnf_filesystem_forced_readonly gauge"
}

# Fields: 5 mountpoint, 6 per-mount options, optional fields up to `-`, then
# fstype, source, superblock options.
{
    for (i = 7; i <= NF && $i != "-"; i++)
        ;
    fstype = $(i + 1)
    source = $(i + 2)

    # systemd credential mounts: `ro` superblock under `rw` by design, as in
    # node_exporter's default `mount-points-exclude`.
    if ($5 ~ /^\/run\/credentials\//)
        next

    # Fault signature: per-mount `rw` over a superblock `ro` (btrfs forced
    # readonly, ext4 `errors=remount-ro`). An intended `ro` mount or bind sets
    # the per-mount flag instead.
    if (("," $6 ",") !~ /,rw,/ || ("," $(i + 3) ",") !~ /,(ro|emergency_ro),/)
        next

    # Stacked mounts can repeat a label set: emit it once.
    line = sprintf("dnf_filesystem_forced_readonly{device=\"%s\",fstype=\"%s\",mountpoint=\"%s\"} 1", esc(source), esc(fstype), esc($5))
    if (!seen[line]++)
        print line
}
