# DNF office: Nextcloud client and GNOME Online Accounts. Doc: `../office.nix` header.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    makeBinPath
    mkForce
    mkIf
    optional
    ;
  cfg = config.darkone.home.office;
  inherit (cfg.shared) nextcloudUrl hasNextcloud hasNextcloudWebdav;

  # Client unit PATH (HM pins the profile only). `xdg-open` needs `gio`
  # (glib), else it probes a browser list without `firefox-esr`: the wizard's
  # "Open" fails, and each click mints a token that voids the copied link.
  nextcloudClientPath = concatStringsSep ":" [
    (makeBinPath [
      pkgs.glib
      pkgs.xdg-utils
    ])
    "${config.home.profileDirectory}/bin"
  ];

  # Nextcloud account in GNOME Online Accounts (files, calendar, contacts).
  # The web UI mints no app password for an OIDC user (user_oidc#468): Login
  # Flow v2, the desktop client's own HTTP API, does. GOA mounts the share and
  # feeds Evolution; a GTK bookmark would be a credential-less duplicate.
  nextcloudWebdavLogin = pkgs.writeShellApplication {
    name = "nextcloud-webdav-login";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      glib
      jq
      libsecret
      xdg-utils
    ];
    text = ''
      server="${toString nextcloudUrl}"
      host="''${server#*://}"
      host="''${host%%/*}"
      goa_conf="''${XDG_CONFIG_HOME:-$HOME/.config}/goa-1.0/accounts.conf"

      # Login Flow v2: anonymous POST, then poll while the user authenticates
      # in the browser. The User-Agent names the app password server-side.
      init="$(curl -fsS -X POST -A "DNF $(uname -n)" "$server/index.php/login/v2")"
      login_url="$(jq -r .login <<< "$init")"
      poll_token="$(jq -r .poll.token <<< "$init")"
      poll_endpoint="$(jq -r .poll.endpoint <<< "$init")"

      echo "Autorisez l'accès dans le navigateur, puis revenez ici."
      xdg-open "$login_url" >/dev/null 2>&1 || echo "URL à ouvrir : $login_url"

      # 404 while pending, 200 once granted. The token lives 20 minutes.
      deadline="$(( $(date +%s) + 1200 ))"
      result=""
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if result="$(curl -fsS -X POST -d "token=$poll_token" "$poll_endpoint" 2>/dev/null)"; then
          break
        fi
        sleep 2
      done

      if [ -z "$result" ]; then
        echo "Délai dépassé : aucune autorisation reçue." >&2
        exit 1
      fi

      # The Nextcloud uid, which is what GOA authenticates with. Never assume
      # it matches the local account: user_oidc derives it from the provider,
      # and a user may well run their services under another login.
      login_name="$(jq -r .loginName <<< "$result")"
      app_password="$(jq -r .appPassword <<< "$result")"

      # Derived from the server, so re-running refreshes the account in place
      # instead of stacking a second one next to it.
      account="account_$(printf '%s' "$server" | cksum | cut -d' ' -f1)_0"

      # Seed the keyring first: rewriting the config file is what makes the
      # daemon reload, so the credential has to already be there. GOA reads a
      # GVariant vardict, and jq supplies the string escaping.
      if ! printf "{'password': <%s>}" "$(jq -n --arg p "$app_password" '$p')" \
        | secret-tool store --label="GOA owncloud credentials for identity $account" \
            xdg:schema org.gnome.OnlineAccounts \
            goa-identity "owncloud:gen0:$account"
      then
        echo "Trousseau inaccessible : compte non enregistré." >&2
        exit 1
      fi

      # Rewrite our own block only; any other account in the file is kept.
      mkdir -p "$(dirname "$goa_conf")"
      touch "$goa_conf"
      tmp="$(mktemp)"
      awk -v drop="[Account $account]" '
        $0 == drop { skip = 1; next }
        /^\[/ { skip = 0 }
        !skip
      ' "$goa_conf" > "$tmp"

      # Mirrors what the GOA "Nextcloud" provider writes itself, explicit port
      # included; the provider is still named `owncloud` internally.
      #
      # `Identity` is the credential half and must stay the Nextcloud uid;
      # `PresentationIdentity` is display only, and gvfs reuses it verbatim to
      # name the mount. Left to the provider's `uid@host` default that reads
      # as `IDM-<uuid>@cloud.example.com` in the file manager sidebar,
      # hence an explicit, human label.
      cat >> "$tmp" <<EOF

      [Account $account]
      Provider=owncloud
      Identity=$login_name
      PresentationIdentity=Nextcloud ($host)
      Uri=https://$host:443/remote.php/webdav/
      FilesEnabled=true
      CalendarEnabled=true
      CalDavUri=https://$host:443/remote.php/dav/
      ContactsEnabled=true
      CardDavUri=https://$host:443/remote.php/dav/
      AcceptSslErrors=false
      EOF
      mv "$tmp" "$goa_conf"
      chmod 644 "$goa_conf"

      # Wakes the daemon when it is not running; when it is, its own file
      # monitor has already picked the account up.
      gdbus introspect --session --dest org.gnome.OnlineAccounts \
        --object-path /org/gnome/OnlineAccounts >/dev/null 2>&1 || true

      echo ""
      echo "  Compte Nextcloud : $login_name"
      echo "  Serveur          : $host"
      echo ""
      echo "Fichiers, agenda et contacts sont reliés à ce compte ; le partage"
      echo "apparaît dans le gestionnaire de fichiers."
      echo ""
      echo "Mot de passe d'application, pour tout autre client WebDAV :"
      echo ""
      echo "    $app_password"
    '';
  };

  # Drops the GTK bookmark the client adds on its sync folder
  # (`Utility::setupFavLink`), a duplicate of the account's sidebar entry.
  # Sync roots read from the client config: the wizard allows any folder.
  nextcloudDropSyncBookmark = pkgs.writeShellApplication {
    name = "nextcloud-drop-sync-bookmark";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      gnused
    ];
    text = ''
      conf_home="''${XDG_CONFIG_HOME:-$HOME/.config}"
      bookmarks="$conf_home/gtk-3.0/bookmarks"
      client_conf="$conf_home/Nextcloud/nextcloud.cfg"

      if [ ! -f "$bookmarks" ] || [ ! -f "$client_conf" ]; then
        exit 0
      fi

      # `0\Folders\1\localPath=/home/me/Nextcloud/`, one line per sync root.
      roots="$(sed -n 's/^[0-9]*\\Folders\\[0-9]*\\localPath=//p' "$client_conf")"
      if [ -z "$roots" ]; then
        exit 0
      fi

      tmp="$(mktemp)"
      while IFS= read -r line; do

        # `URI [label]`, percent-encoded once the file manager has rewritten
        # the file; `%b` turns `%C3%A9` back into the raw UTF-8 bytes.
        uri="''${line%% *}"
        target="''${uri#file://}"
        target="$(printf '%b' "''${target//%/\\x}")"
        keep=1
        while IFS= read -r root; do
          if [ -n "$root" ] && [ "''${target%/}" = "''${root%/}" ]; then
            keep=0
          fi
        done <<< "$roots"
        if [ "$keep" = 1 ]; then
          printf '%s\n' "$line"
        fi
      done < "$bookmarks" > "$tmp"

      # Rewrite only on a real change: the path unit driving this watches the
      # very file being written.
      if ! cmp -s "$tmp" "$bookmarks"; then
        cat "$tmp" > "$bookmarks"
      fi
      rm -f "$tmp"
    '';
  };
in
{
  # Installed by the office package list.
  options.darkone.home.office.nextcloud.webdavLogin = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    default = nextcloudWebdavLogin;
    description = "`nextcloud-webdav-login` helper, installed by the office package list.";
  };

  config = mkIf cfg.enable {
    services.nextcloud-client = mkIf hasNextcloud {
      enable = true;
      startInBackground = true;
    };

    # Wizard pre-fill in ExecStartPre: the `--override*` flags write the
    # client config, then exit. With the server set, the wizard goes straight
    # to browser (Kanidm SSO) authentication; no folder, no forced sync.
    systemd.user.services.nextcloud-client = mkIf hasNextcloud {

      # `-`: a failed pre-fill must not cost the user their client. The wizard
      # then merely opens with an empty server field.
      Service.ExecStartPre =
        "-"
        + concatStringsSep " " (
          [
            "${pkgs.nextcloud-client}/bin/nextcloud"
            "--overrideserverurl ${toString nextcloudUrl}"
          ]
          ++ optional (
            cfg.nextcloud.syncDir != null
          ) "--overridelocaldir ${config.home.homeDirectory}/${toString cfg.nextcloud.syncDir}"
        );

      # Without this the wizard's "Open" button cannot reach a browser, see
      # `nextcloudClientPath`.
      Service.Environment = mkForce [ "PATH=${nextcloudClientPath}" ];

      # Computed rather than conditional: the unit stays defined either way, so
      # `systemctl --user start nextcloud-client` still works when auto-start
      # is off.
      Install.WantedBy = mkForce (optional cfg.nextcloud.enableAutoStart "graphical-session.target");
    };

    # Watch the bookmarks file rather than patch it once: the client writes
    # its entry when the user finishes the wizard, long after activation.
    systemd.user.services.nextcloud-drop-sync-bookmark = mkIf hasNextcloud {
      Unit = {
        Description = "Remove the duplicate Nextcloud sync folder bookmark";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${nextcloudDropSyncBookmark}/bin/nextcloud-drop-sync-bookmark";
      };

      # Also on login: `PathChanged` never fires for a file already sitting
      # there when the path unit starts.
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    systemd.user.paths.nextcloud-drop-sync-bookmark = mkIf hasNextcloud {
      Unit = {
        Description = "Watch the GTK bookmarks for the Nextcloud sync entry";
      };
      Path = {
        PathChanged = "${config.xdg.configHome}/gtk-3.0/bookmarks";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    # The client writes its own autostart entry (`Utility::setLaunchOnStartup`,
    # called on every config migration) and that entry launches it bare, with
    # no pre-filled server, racing the unit above. `Hidden=true` is the XDG way
    # to retire an autostart entry; as a store symlink it also survives the
    # client trying to write the file back.
    xdg.configFile."autostart/Nextcloud.desktop" = mkIf hasNextcloud {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Nextcloud
        Hidden=true
      '';
    };

    # A workstation that ran the client before this module carries that entry
    # as a real file, and home-manager aborts rather than clobber one. Retire
    # it before the link check, keeping a copy: activation must not destroy
    # something the user could have edited.
    home.activation.retireNextcloudAutostart = mkIf hasNextcloud (
      lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        entry="${config.xdg.configHome}/autostart/Nextcloud.desktop"
        if [ -f "$entry" ] && [ ! -L "$entry" ]; then
          run mv $VERBOSE_ARG "$entry" "$entry.dnf-backup"
        fi
      ''
    );

    # Connecting the account needs a credential the web UI cannot issue to an
    # OIDC user; this entry runs the Login Flow v2 helper in a terminal.
    #
    # Short name on purpose: the GNOME grid ellipsises past ~14 characters, so
    # the first word is all the user gets to tell this icon apart from the
    # sync client sitting next to it.
    xdg.desktopEntries.nextcloud-webdav-login = mkIf hasNextcloudWebdav {
      name = "Webdav Login";
      genericName = "Nextcloud Online Account";
      comment = "Link files, calendar and contacts to my Nextcloud account";
      exec = "${nextcloudWebdavLogin}/bin/nextcloud-webdav-login";
      icon = "nextcloud";
      terminal = true;
      type = "Application";
      categories = [
        "Network"
        "FileTransfer"
      ];
    };
  };
}
