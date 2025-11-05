{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.zed;
in
{
  options = {
    darkone.home.zed.enable = lib.mkEnableOption "Preconfigured ZED editor";
    darkone.home.zed.enableAssistant = lib.mkEnableOption "Enable AI Assistant";
  };

  config = lib.mkIf cfg.enable {

    # Editor
    programs.zed-editor = {
      enable = true;
      extensions = [
        "nix"
        "toml"
        "php"
        "xml"
        "php"
        "catppuccin"
        "html"
        "astro"
        "justfile"
        "make"
      ];

      # Zed options -> json config
      userSettings = {

        # AI Assistant (wip)
        assistant = lib.mkIf cfg.enableAssistant {
          enabled = true;
          version = "2";
          default_open_ai_model = null;

          ### PROVIDER OPTIONS
          ### zed.dev models { claude-3-5-sonnet-latest } requires github connected
          ### anthropic models { claude-3-5-sonnet-latest claude-3-haiku-latest claude-3-opus-latest  } requires API_KEY
          ### copilot_chat models { gpt-4o gpt-4 gpt-3.5-turbo o1-preview } requires github connected
          default_model = {
            provider = "zed.dev";
            model = "claude-3-5-sonnet-latest";
          };
          #                inline_alternatives = [
          #                    {
          #                        provider = "copilot_chat";
          #                        model = "gpt-3.5-turbo";
          #                    }
          #                ];
        };

        node = {
          path = lib.getExe pkgs.nodejs;
          npm_path = lib.getExe' pkgs.nodejs "npm";
        };

        hour_format = "hour24";
        auto_update = false;
        terminal = {
          alternate_scroll = "off";
          blinking = "off";
          copy_on_select = false;
          dock = "bottom";
          detect_venv = {
            on = {
              directories = [
                ".env"
                "env"
                ".venv"
                "venv"
              ];
              activate_script = "default";
            };
          };
          font_family = "JetBrainsMono Nerd Font Mono";
          font_features = null;
          font_size = 16;
          line_height = "comfortable";
          option_as_meta = false;
          button = false;
          shell = "system";
          toolbar = {
            title = true;
          };
          working_directory = "current_project_directory";
        };

        lsp = {
          rust-analyzer = {
            binary = {
              path_lookup = true;
            };
          };
          nix = {
            binary = {
              path_lookup = true;
            };
          };
        };

        ## tell zed to use direnv and direnv can use a flake.nix environment.
        load_direnv = "shell_hook";
        base_keymap = "VSCode";
        theme = {
          mode = "system";
          light = "One Light";
          dark = "One Dark";
        };
        ui_font_size = 16;
        buffer_font_size = 16;
      };
    };
  };
}
