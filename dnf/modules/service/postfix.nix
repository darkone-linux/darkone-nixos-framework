# Postfix SMTP Relay.

{
  lib,
  config,
  network,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.postfix;
  inherit (network) smtp;

  # Match les adresses sans point dans le domaine (ex: user@host) -> noreply@domain.tld
  senderCanonicalFile = pkgs.writeText "postfix-sender-canonical" ''
    /^[^@]+@[^.]+$/ noreply@${network.domain}
  '';
in
{
  options = {
    darkone.service.postfix.enable = lib.mkEnableOption "Enable Postfix SMTP Relay";
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Sops
    #--------------------------------------------------------------------------

    sops.secrets."smtp/password" = { };
    sops.templates.postfix-sasl-password = {
      mode = "0400";
      owner = "postfix";
      content = ''
        [${smtp.server}]:${toString smtp.port} ${smtp.username}:${config.sops.placeholder."smtp/password"}
      '';
    };

    #--------------------------------------------------------------------------
    # Postfix relay
    #--------------------------------------------------------------------------

    services.postfix = {
      enable = true;

      # main.cf
      settings.main = {

        # Paramètres du relai
        relayhost = [ "[${smtp.server}]:${toString smtp.port}" ];
        relay_domains = [ network.domain ];
        inet_protocols = "ipv4";
        mynetworks = [
          "10.0.0.0/8"
          "100.64.0.0/10"
          "127.0.0.0/8"
        ];

        # Remplacement du sender incomplet
        sender_canonical_maps = "regexp:${senderCanonicalFile}";

        # Configuration TLS
        smtp_tls_security_level = lib.mkIf smtp.tls "encrypt";
        smtp_tls_wrappermode = lib.mkIf smtp.tls "yes";
        smtp_tls_loglevel = lib.mkIf smtp.tls "1";

        # Authentification SASL
        smtp_sasl_auth_enable = lib.mkIf smtp.tls "yes";
        smtp_sasl_security_options = "noanonymous";
        smtp_sasl_password_maps = "texthash:${config.sops.templates.postfix-sasl-password.path}";

        # Paramètres de sécurité additionnels
        smtputf8_enable = "no";
      };
    };
  };
}
