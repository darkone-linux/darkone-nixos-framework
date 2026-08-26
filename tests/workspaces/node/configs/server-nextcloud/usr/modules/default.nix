# Consumer modules overlay for the nextcloud variant.
#
# `whiteboard` is not a default plugin, and its wiring (sops template, occ
# provisioning unit, backend daemon) sits behind `mkIf`, so it would never be
# type-checked otherwise. Enabling it here keeps that path under the eval guard.
{ lib, ... }: {
  darkone.service.nextcloud.plugins = lib.mkForce [
    "calendar"
    "contacts"
    "whiteboard"
  ];
}
