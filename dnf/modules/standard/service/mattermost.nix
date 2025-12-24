# A mattermost server. (WIP)
#
# :::caution
# This module works with Mattermost Team Edition but I do not plan
# to maintain it because of the removal of the SSO functionality
# from the open-source version.
# :::

{
  lib,
  dnfLib,
  pkgs,
  config,
  host,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.mattermost;
  srv = config.services.mattermost;
  defaultParams = {
    description = "Messaging and collaboration";
    icon = "mattermost-light";
  };
  params = dnfLib.extractServiceParams host network "mattermost" defaultParams;
  mattermostEmail = "mattermost@${network.domain}";
in
{
  options = {
    darkone.service.mattermost.enable = lib.mkEnableOption "Enable mattermost service";
    darkone.service.mattermost.enableSmtp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SMTP to send emails (recommended)";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.mattermost = {
        inherit defaultParams;
        persist.varDirs = [ "${srv.dataDir}/data" ];
        persist.dbDirs = [ config.services.postgresql.dataDir ];
        proxy.servicePort = srv.port;
        proxy.extraConfig = ''
          header {
            X-Frame-Options "SAMEORIGIN"
            X-Content-Type-Options "nosniff"
            Referrer-Policy "no-referrer-when-downgrade"
          }
          request_body {
            max_size 200MB
          }
          encode gzip

          # Hack for mattermost healthcheck (not working)
          #@mmhealth {
          #  path /api/v4/site_url/test
          #}
          #handle @mmhealth {
          #  reverse_proxy ${params.ip}:${toString srv.port}
          #}
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.mattermost.enable = true;
      };

      #--------------------------------------------------------------------------
      # Security
      #--------------------------------------------------------------------------

      # Données d'environnement critiques hébergée par sops
      sops.secrets.mattermost-env = lib.mkIf cfg.enableSmtp {
        mode = "0400";
        group = "mattermost";
      };

      #--------------------------------------------------------------------------
      # Utilities
      #--------------------------------------------------------------------------

      # Tools
      environment.systemPackages = with pkgs; [ mmctl ];

      #------------------------------------------------------------------------
      # Mattermost Server
      #------------------------------------------------------------------------

      # TODO: bulk users
      # -> https://docs.mattermost.com/administration-guide/onboard/bulk-loading-data.html
      # -> https://docs.mattermost.com/administration-guide/onboard/user-provisioning-workflows.html
      services.mattermost = {
        enable = true;
        siteUrl = params.href;
        siteName = params.title;
        host = params.ip;
        package = pkgs.mattermostLatest;
        mutableConfig = false; # default - configuration is overwriten by theses params

        # https://docs.mattermost.com/administration-guide/configure/configuration-settings.html
        settings = {
          ServiceSettings = {
            EnableDesktopLandingPage = false;
            EnableEmailInvitations = true;
            MaximumLoginAttempts = 10;
            SessionLengthMobileInDays = 60;
            SessionLengthMobileInHours = 1440;
            EnableSVGs = true;
            EnableInlineLatex = true;
          };
          TeamSettings = {
            SiteName = params.title;
            CustomDescriptionText = params.description;
            EnableUserCreation = true; # default
            RestrictCreationToDomains = ""; # Or true, restrict email domain to mm domain
            EnableOpenServer = false; # False = only create an account with an invitation
          };
          LocalizationSettings = {
            DefaultServerLocale = zone.lang;
            DefaultClientLocale = zone.lang;
          };
          EmailSettings = {
            SendEmailNotifications = cfg.enableSmtp;
            EnableSMTPAuth = cfg.enableSmtp; # TODO: true
            EnableSignUpWithEmail = true; # TODO: false with bulk user?
            EnableSignInWithUsername = true;
            RequireEmailVerification = cfg.enableSmtp;
            FeedbackName = "Notification Mattermost";
            FeedbackEmail = mattermostEmail;
            ReplyToAddress = mattermostEmail;
            EnablePreviewModeBanner = false;
          };
          MetricsSettings = {
            EnableNotificationMetrics = false;
          };
          SupportSettings = {
            EnableAskCommunityLink = false;
            ReportAProblemLink = "";
            ReportAProblemMail = mattermostEmail;
            ReportAProblemType = "email";
            AllowDownloadLogs = false;
            SupportEmail = mattermostEmail;
            PrivacyPolicyLink = "";
            AboutLink = "";
          };
          PasswordSettings = {
            MinimumLength = 10;
            Lowercase = true;
            Uppercase = true;
            Number = true;
            Symbol = false;
          };
          PrivacySettings = {
            ShowEmailAddress = false;
            ShowFullName = true;
          };
          LdapSettings = {
            ForgotPasswordLink = cfg.enableSmtp;
          };
        };

        # Avec sops-nix, dans mattermost-env :
        # MM_EMAILSETTINGS_SMTPSERVER=""
        # MM_EMAILSETTINGS_SMTPPORT=""
        # MM_EMAILSETTINGS_SMTPUSERNAME=""
        # MM_EMAILSETTINGS_CONNECTIONSECURITY="TLS"
        # MM_EMAILSETTINGS_SMTPPASSWORD=""
        environmentFile = config.sops.secrets.mattermost-env.path;
      };
    })
  ];
}
