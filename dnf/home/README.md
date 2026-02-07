# Homes files

> [!NOTE]
> Several users can have the same profile.

Depending on the user's profile (in this case “admin”), the flake will load specific nixos configuration for this profile (`nixos/admin.nix`) and then load the user's home-manager profile (`admin/default.nix`) of the related user.

```
nixos/admin.nix      <-- NixOS additional configuration for the "admin" profile
profiles/admin/(...) <-- Home Manager configuration bootstraps
modules/(...)        <-- Home Manager modules
```
