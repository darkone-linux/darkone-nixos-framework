# Homes files

> [!NOTE]
> Several users can have the same profile.

Depending on the user's profile (in this case “admin”), the flake will first create the user using `admin.nix` and then load the user's home-manager profile `admin/default.nix`.

```
admin.nix   <-- Admin user creation with darkone.user.xxx.enable and additional options
admin/(...) <-- Home Manager specific files
```
