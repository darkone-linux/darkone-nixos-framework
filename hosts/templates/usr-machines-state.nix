# Frozen at install (`just install`): never change
#
# Kept on reinstall (restores data such as databases). Delete it only to
# rebuild this host as a new machine: next install freezes the new release.

{ system.stateVersion = "@STATE_VERSION@"; }
