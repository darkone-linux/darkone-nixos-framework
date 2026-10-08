# Host profile: UMI (Unified Multimodal Input) workstation, usable without keyboard/mouse.
#
# :::note[UMI: Unified Multimodal Input]
# Accessibility goal: coordinated inputs (touch, voice, gaze…) replace keyboard
# and mouse, combined to fit the user's abilities. Current stack: Onboard on a
# touchscreen, Talon voice commands, Tobii Eye Tracker 5 driven through Talon.
# :::
#
# :::note[Extends desktop]
# Inherits the full desktop profile (GNOME, multimedia, office) and adds the
# UMI prerequisites: a Cinnamon X11 session for UMI users (dark mode by
# default), auto-login, uinput event injection and Tobii udev rules.
# :::
#
# :::tip[X11 / Wayland coexistence]
# Talon requires X11 (Wayland unsupported upstream, not planned) and
# GNOME 50 dropped its Xorg session, so UMI sessions run Cinnamon (X11,
# GNOME-like UX, native tray) while other users keep GNOME Wayland. The
# host users whose home enables `darkone.home.umi` (`umi` user profile) get
# their saved GDM session pinned to "cinnamon" through AccountsService, at
# every boot: a keyboard-free user cannot pick a session at the greeter.
# :::
#
# :::caution[Talon package]
# `pkgs.talon` comes from the `talon-nix` input wired in the DNF flake
# (x86_64-linux only, unfree upstream tarball). With `package = null`,
# udev/uinput/a11y are still configured and Talon can be run manually
# (steam-run on the upstream tarball, which keeps auto-update working).
# :::
#
# :::tip[First run]
# The Tobii 5 firmware must be initialized once on a Windows machine
# (Tobii Experience). On first Talon start, replug the tracker then
# restart Talon (udev), and run the calibration from the Talon menu.
# :::
#
# :::caution[No mousetweaks]
# muffin does dwell clicks itself (click types from the panel). A mousetweaks
# daemon in the session would dwell in parallel with plain left clicks (the
# chosen type is never used), pop its "Hover Click" window and grab the mouse
# wheel on the root window until logout (`XGrabButton` on buttons 4/5).
# :::
#
# :::note[Expected kernel noise]
# The tracker declares two video-class interfaces (raw IR eye cameras) that
# uvcvideo cannot handle: `Unknown video format`, `No supported video formats
# found`, `probe with driver uvcvideo failed with error -22`. Harmless and
# wanted: no kernel driver claims the interfaces, so libusb gets them free.
# The tracker is reached through interface 0 (vendor-specific, bulk
# endpoints), never through /dev/video*.
# :::
{
  lib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.host.umi;

  # Users whose GDM session must be the Cinnamon X11 one, read from their home
  # so that a consumer profile importing `umi` counts too.
  umiUsers = lib.filter (
    login: config.home-manager.users.${login}.darkone.home.umi.enable or false
  ) host.users;

  # GSettings schema defaults of each desktop, rebuilt from its own options as
  # its nixpkgs module does (only one of them can own the global variable).
  gnomeCfg = config.services.desktopManager.gnome;
  gnomeOverrides = pkgs.gnome.nixos-gsettings-overrides.override {
    inherit (gnomeCfg) extraGSettingsOverrides extraGSettingsOverridePackages favoriteAppsOverride;
    flashbackEnabled = gnomeCfg.flashback.enableMetacity || gnomeCfg.flashback.customSessions != [ ];
  };
  cinnamonOverrides = pkgs.cinnamon-gsettings-overrides.override {
    inherit (config.services.xserver.desktopManager.cinnamon)
      extraGSettingsOverridePackages
      extraGSettingsOverrides
      ;
  };
  schemasOf =
    overrides: "${overrides}/share/gsettings-schemas/nixos-gsettings-overrides/glib-2.0/schemas";

  # Onboard without its mousetweaks integration (off when the schema is
  # missing, as on Mint). csd mirrors Cinnamon's dwell key to GNOME's, Onboard
  # then starts mousetweaks: cf. the "No mousetweaks" note in the header.
  onboard = pkgs.onboard.override { mousetweaks = pkgs.emptyDirectory; };
in
{
  options = {
    darkone.host.umi = {
      enable = lib.mkEnableOption "UMI host configuration: multimodal input, touch + voice + gaze (Onboard, Talon, Tobii)";
      autoLoginUser = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Auto-login user (mandatory for a keyboard-free session), a host user with the `umi` profile.";
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = pkgs.talon or null;
        description = "Talon package (defaults to `pkgs.talon` from the talon-nix overlay when available).";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Full workstation base (GNOME Wayland for non-UMI users)
    darkone.host.desktop.enable = lib.mkDefault true;

    # Microphone for Talon voice commands, speakers for typing feedback
    darkone.service.audio.enable = lib.mkDefault true;

    # X11 desktop for the UMI sessions, launched by GDM alongside GNOME
    services.xserver.desktopManager.cinnamon.enable = true;

    # Dark mode of the Mint-Y style, as Cinnamon's Themes page writes it (panel
    # already dark): user-overridable defaults, GNOME sessions are dark too.
    services.xserver.desktopManager.cinnamon.extraGSettingsOverrides = ''
      [org.cinnamon.desktop.interface]
      gtk-theme='Mint-Y-Dark-Aqua'

      [org.x.apps.portal]
      color-scheme='prefer-dark'
    '';

    # Both desktops set this variable globally (nixpkgs). GNOME's wins: GNOME
    # sessions and the GDM greeter read it, and Cinnamon's Mint defaults would
    # leak there (fonts, an uninstalled `DMZ-White` cursor: grey-square pointer).
    environment.sessionVariables.NIX_GSETTINGS_OVERRIDES_DIR = lib.mkForce (schemasOf gnomeOverrides);

    # Cinnamon's defaults for the X11 sessions only: GDM starts them through
    # the NixOS xsession wrapper, never GNOME 50 (Wayland) nor the greeter.
    services.xserver.displayManager.sessionCommands = ''
      export NIX_GSETTINGS_OVERRIDES_DIR=${schemasOf cinnamonOverrides}
      ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd NIX_GSETTINGS_OVERRIDES_DIR
    '';

    # Pin the UMI users' saved GDM session: `f+` rewrites it at every boot and
    # activation, so a session picked once (or an account known before) cannot
    # stick. Their other AccountsService keys (Icon, Language) are dropped.
    systemd.tmpfiles.rules = map (
      login: "f+ /var/lib/AccountsService/users/${login} 0600 root root - [User]\\nSession=cinnamon\\n"
    ) umiUsers;

    # A lock screen or a password prompt is a dead-end without a keyboard.
    services.displayManager.autoLogin = lib.mkIf (cfg.autoLoginUser != null) {
      enable = true;
      user = cfg.autoLoginUser;
    };

    # A non-UMI autologin user lands in GNOME Wayland (no Talon) and keeps a
    # keyring nobody can unlock (cf. `darkone.home.umi`).
    assertions = [
      {
        assertion = cfg.autoLoginUser == null || lib.elem cfg.autoLoginUser umiUsers;
        message = ''
          darkone.host.umi.autoLoginUser = "${toString cfg.autoLoginUser}" on ${host.hostname} is not
          a user of this host with the `umi` profile (UMI users: ${lib.concatStringsSep ", " umiUsers}).
          List the login in the host `users` of etc/config.yaml and give it `profile: "umi"`.
        '';
      }

      # GDM's preStart then runs `set-session`, which forces that session on
      # every normal user at each start: the pin above would be overwritten.
      {
        assertion = config.services.displayManager.defaultSession == null;
        message = ''
          services.displayManager.defaultSession is set on UMI host ${host.hostname}: GDM would
          force it on every user, UMI users included (Cinnamon session lost). Leave it unset,
          GDM already falls back to GNOME for the other users.
        '';
      }
    ];

    # Consequence for the GNOME keyring: the session receives no password, so
    # nothing unlocks it by itself. On an encrypted host the boot passphrase
    # takes that role (systemd-cryptsetup caches it in root's kernel keyring,
    # `pam_gdm` — already in the gdm-autologin stack — hands it to
    # pam_gnome_keyring); elsewhere `darkone.home.umi` seeds a passwordless
    # keyring. Both modes are documented in that home module's header.

    # `su` hands over the X cookie (pam_xauth, NixOS default): a CLI run as
    # another user then pops its keyring prompts on the UMI display, and a gcr
    # system prompt grabs it — a dead end without a keyboard.
    security.pam.services.su.forwardXAuth = lib.mkForce false;

    # Known GNOME + autologin workaround (double getty race)
    systemd.services."getty@tty1".enable = lib.mkIf (cfg.autoLoginUser != null) false;
    systemd.services."autovt@tty1".enable = lib.mkIf (cfg.autoLoginUser != null) false;

    # Session units ignoring SIGTERM (`gdm-session-worker [pam/gdm-autologin]`,
    # VBoxClient services) die on the stop timeout only: minutes of shutdown at
    # the 90s default, for no state worth a long drain. Both managers: the
    # session scope inherits the system default, VBoxClient the per-user one.
    systemd.settings.Manager.DefaultTimeoutStopSec = "5s";
    systemd.user.settings.Manager.DefaultTimeoutStopSec = "5s";

    # Desktop cleanup: apps duplicating a retained one (Xed vs GNOME Text
    # Editor, stock Onboard vs ours), useless without a second peer
    # (Warpinator) or unusable without a keyboard (Seahorse — the keyring is
    # passwordless here, cf. home module).
    environment.cinnamon.excludePackages = [
      pkgs.onboard
      pkgs.warpinator
      pkgs.xed-editor

      # Its Bibata themes collide in system-path with `bibata-cursors`
      # (gnome.nix), the GNOME cursor source; its other themes go unused.
      pkgs.mint-cursor-themes
    ];
    environment.gnome.excludePackages = [ pkgs.seahorse ];

    # Talon injects mouse/keyboard events through /dev/uinput; the NixOS
    # module creates the "uinput" group, the static node and its udev rule.
    # UMI users join input/uinput via `home/nixos/umi.nix`.
    hardware.uinput.enable = true;

    # Tobii consumer trackers (USB vendor 2104): r/w for the logged-in user, as
    # Talon's stream engine claims the vendor interface through libusb. The rule
    # MUST sort before systemd's 73-seat-late.rules (which runs `uaccess`):
    # `services.udev.extraRules` lands in 99-local.rules, too late for any ACL.
    services.udev.packages = [
      (pkgs.writeTextFile {
        name = "tobii-udev-rules";
        destination = "/etc/udev/rules.d/70-tobii.rules";
        text = ''
          SUBSYSTEM=="usb", ATTRS{idVendor}=="2104", MODE="0660", TAG+="uaccess"
        '';
      })
    ];

    # Talon itself (if available), Onboard system-wide (docked on-screen
    # keyboard). Dwell click is native in muffin and mutter: no mousetweaks.
    environment.systemPackages = lib.optional (cfg.package != null) cfg.package ++ [ onboard ];
  };
}
