# `usr/users/<login>/`

One directory per user, containing a hand-written `default.nix` layered on top
of the user's home-manager profile (extra packages, shell aliases, dotfiles).

> [!IMPORTANT]
> A directory is **required** for every login the generator emits — the ones
> you declare in `etc/config.yaml:users`, plus the implicit `nix` maintenance
> account. It is imported unconditionally: a missing directory fails the
> evaluation with `error: path '…/usr/users/<login>' does not exist`.

Minimal example, `usr/users/alice/default.nix`:

```nix
{ pkgs, ... }:
{
  home.packages = with pkgs; [ ripgrep fd ];

  programs.git = {
    enable = true;
    userName = "Alice";
    userEmail = "alice@example.lan";
  };
}
```

An empty `{ }` is perfectly valid when the profile already says it all.
