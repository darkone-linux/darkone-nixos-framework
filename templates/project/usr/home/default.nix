# Home manager entry point of this deployment.
#
# Imported for every user of every host, on top of the framework's own
# home-manager modules. Put here what is common to all your users; per-user
# settings belong to `usr/users/<login>/default.nix`.

{ imports = [ ./modules ]; }
