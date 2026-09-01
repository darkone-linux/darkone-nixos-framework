# Host profile: gaze-driven workstation (Tobii Eye Tracker 5 + Talon), usable without keyboard/mouse.
#
# :::note[Extends desktop]
# Inherits the full desktop profile (GNOME, multimedia, office) and adds the
# gaze prerequisites: a Cinnamon X11 session for gaze users, auto-login,
# uinput event injection and Tobii udev rules.
# :::
#
# :::tip[X11 / Wayland coexistence]
# Talon requires X11 (Wayland unsupported upstream, not planned) and
# GNOME 50 dropped its Xorg session, so gaze sessions run Cinnamon (X11,
# GNOME-like UX, native tray) while other users keep GNOME Wayland. The
# users listed in `gazeUsers` (plus `autoLoginUser`) get their saved GDM
# session seeded to "cinnamon" through AccountsService; GDM keeps managing
# the file afterwards.
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
  ...
}:
let
  cfg = config.darkone.host.umi;

  # Users whose GDM session must be the Cinnamon X11 one (gaze sessions)
  gazeSessionUsers = lib.unique (
    cfg.gazeUsers ++ lib.optional (cfg.autoLoginUser != null) cfg.autoLoginUser
  );
in
{
  options = {
    darkone.host.umi = {
      enable = lib.mkEnableOption "Eye-tracking optimized host configuration (Tobii + Talon)";
      autoLoginUser = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Auto-login user (mandatory for a keyboard-free session).";
      };
      gazeUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Gaze users whose GDM session is seeded to Cinnamon/X11 (autoLoginUser is always included).";
      };
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = pkgs.talon or null;
        description = "Talon package (defaults to `pkgs.talon` from the talon-nix overlay when available).";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Full workstation base (GNOME Wayland for non-gaze users)
    darkone.host.desktop.enable = lib.mkDefault true;

    # Microphone for Talon voice commands, speakers for typing feedback
    darkone.service.audio.enable = lib.mkDefault true;

    # X11 desktop for the gaze sessions, launched by GDM alongside GNOME
    services.xserver.desktopManager.cinnamon.enable = true;

    # GNOME and Cinnamon both define this variable (nixpkgs limitation when
    # two desktops coexist): arbitrate with Cinnamon's exact value. GNOME
    # sessions only lose schema *defaults* (background, favorite apps) that
    # DNF re-imposes anyway through its locked dconf databases; Cinnamon
    # sessions keep their correct Mint defaults.
    environment.sessionVariables.NIX_GSETTINGS_OVERRIDES_DIR = lib.mkForce "${
      pkgs.cinnamon-gsettings-overrides.override {
        inherit (config.services.xserver.desktopManager.cinnamon)
          extraGSettingsOverridePackages
          extraGSettingsOverrides
          ;
      }
    }/share/gsettings-schemas/nixos-gsettings-overrides/glib-2.0/schemas";

    # Seed the gaze users' saved GDM session ("f" writes only when the file
    # is missing, GDM keeps managing it afterwards). Other users keep their
    # GNOME Wayland session.
    systemd.tmpfiles.rules = map (
      login: "f /var/lib/AccountsService/users/${login} 0644 root root - [User]\\nSession=cinnamon\\n"
    ) gazeSessionUsers;

    # A lock screen or a password prompt is a dead-end without a keyboard.
    services.displayManager.autoLogin = lib.mkIf (cfg.autoLoginUser != null) {
      enable = true;
      user = cfg.autoLoginUser;
    };

    # Consequence for the GNOME keyring: the session receives no password, so
    # nothing unlocks it by itself. On an encrypted host the boot passphrase
    # takes that role (systemd-cryptsetup caches it in root's kernel keyring,
    # `pam_gdm` — already in the gdm-autologin stack — hands it to
    # pam_gnome_keyring); elsewhere `darkone.home.umi` seeds a passwordless
    # keyring. Both modes are documented in that home module's header.

    # Known GNOME + autologin workaround (double getty race)
    systemd.services."getty@tty1".enable = lib.mkIf (cfg.autoLoginUser != null) false;
    systemd.services."autovt@tty1".enable = lib.mkIf (cfg.autoLoginUser != null) false;

    # Several units of a desktop session ignore SIGTERM and only die on the
    # stop timeout: `gdm-session-worker [pam/gdm-autologin]` (GDM gives up on
    # it first: "isn't dying after 5 seconds, now ignoring it") and, user-side,
    # the VBoxClient guest services. At the 90s default that is minutes of
    # shutdown. Nothing here holds state worth a long drain.
    #
    # Both managers are needed: the session scope belongs to the system one
    # (logind never sets TimeoutStopUSec on it, so it inherits this default),
    # the VBoxClient services to the per-user one.
    systemd.settings.Manager.DefaultTimeoutStopSec = "5s";
    systemd.user.settings.Manager.DefaultTimeoutStopSec = "5s";

    # Desktop cleanup: apps duplicating a retained one (Xed vs GNOME Text
    # Editor), useless without a second peer (Warpinator) or unusable without a
    # keyboard (Seahorse — the keyring is passwordless here, cf. home module).
    environment.cinnamon.excludePackages = [
      pkgs.warpinator
      pkgs.xed-editor
    ];
    environment.gnome.excludePackages = [ pkgs.seahorse ];

    # Talon injects mouse/keyboard events through /dev/uinput; the NixOS
    # module creates the "uinput" group, the static node and its udev rule.
    # Gaze users join input/uinput via `home/nixos/umi.nix`.
    hardware.uinput.enable = true;

    # Tobii consumer trackers (USB vendor 2104): grant device access to the
    # logged-in user without root. Talon's Tobii stream engine claims the
    # vendor-specific interface through libusb, which needs r/w on
    # /dev/bus/usb/*.
    #
    # The rule MUST sort before systemd's 73-seat-late.rules, which is what
    # actually runs `RUN{builtin}+="uaccess"` for tagged devices. A rule added
    # through `services.udev.extraRules` lands in 99-local.rules, i.e. after
    # 73: the tag is set too late, no ACL is ever granted and MODE="0660" only
    # makes the node *less* reachable (verified on hardware, tracker 2104:0313).
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
    # keyboard) and mousetweaks (dwell click daemon, GNOME/Cinnamon a11y)
    environment.systemPackages =
      lib.optional (cfg.package != null) cfg.package
      ++ (with pkgs; [
        onboard
        mousetweaks
      ]);
  };
}
