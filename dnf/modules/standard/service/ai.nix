# Artifical Intelligence (open-webui + ollama + llms).

{ lib, config, ... }:
let
  cfg = config.darkone.service.ai;
  internalPort = 9758;
  defaultParams = {
    description = "Local AI";
  };
in
{
  options = {
    darkone.service.ai.enable = lib.mkEnableOption "Enable local AI service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.ai = {
        inherit defaultParams;
        persist = {
          dirs = [ config.services.open-webui.stateDir ];
        };
        proxy.servicePort = internalPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.ai.enable = true;
      };

      #------------------------------------------------------------------------
      # Ollama service
      #------------------------------------------------------------------------

      services.ollama = {
        enable = true;
      };

      #------------------------------------------------------------------------
      # Immich Service
      #------------------------------------------------------------------------

      # Main immich service configuration
      services.open-webui = {
        enable = true;
        port = internalPort;
        environment = {
          ANONYMIZED_TELEMETRY = "False";
          DO_NOT_TRACK = "True";
          SCARF_NO_ANALYTICS = "True";
          OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
          WEBUI_AUTH = "False";
        };
      };
    })
  ];
}
