# DNF office: `md2pdf` and the pandoc toolchain. Doc: `../office.nix` header.

{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    getExe
    getExe'
    mkIf
    optional
    ;
  cfg = config.darkone.home.office;
  inherit (cfg.shared) lang country;

  pandocLang = "${lang}-${country}";

  # typst: faster, and its output compared better than ConTeXt's. ConTeXt
  # stays reachable through `-e context` / `--pdf-engine=context`.
  pandocEngine = "typst";

  # Lowest-priority metadata: a document's YAML block, `-M` and `-V` all win
  # over it, whereas a defaults `variables` entry turns into a list next to a
  # `-V` of the same name.
  pandocMetadata = (pkgs.formats.yaml { }).generate "pandoc-metadata.yaml" {
    lang = pandocLang;
    mainfont = "Gentium";
    monofont = "DejaVu Sans Mono";
  };

  # Falls back on the GECOS full name, then on the login.
  md2pdfAuthor =
    let
      fullName = osConfig.users.users.${config.home.username}.description or "";
    in
    if cfg.pandocAuthor != null then
      cfg.pandocAuthor
    else if fullName != "" then
      fullName
    else
      config.home.username;

  # Calls the unwrapped pandoc: md2pdf states every setting itself and must not
  # inherit `programs.pandoc.defaults`.
  md2pdf = pkgs.writeShellApplication {
    name = "md2pdf";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.exiftool
      pkgs.librsvg
      pkgs.pandoc
      pkgs.typst
    ]
    ++ optional cfg.enablePandocContext pkgs.texliveConTeXt;
    runtimeEnv = {
      MD2PDF_ENGINE = pandocEngine;
      MD2PDF_AUTHOR = md2pdfAuthor;
      MD2PDF_METADATA = "${pandocMetadata}";
      MD2PDF_LINKS_FILTER = "${./../../../assets/pandoc/md2pdf-links.lua}";
      MD2PDF_RAWTEX_FILTER = "${./../../../assets/pandoc/md2pdf-rawtex.lua}";
      MD2PDF_TABLES_FILTER = "${./../../../assets/pandoc/md2pdf-tables.lua}";
      MD2PDF_TYPST_TEMPLATE = "${./../../../assets/pandoc/md2pdf.typ}";
      MD2PDF_CONTEXT_HEADER = "${./../../../assets/pandoc/md2pdf-context.tex}";

      # Typst finds the fonts without relying on the user's fontconfig state.
      # ConTeXt needs nothing: texlive ships Gentium and DejaVu.
      TYPST_FONT_PATHS = concatStringsSep ":" [
        "${pkgs.gentium}/share/fonts"
        "${pkgs.dejavu_fonts}/share/fonts"
      ];
    };
    text = builtins.readFile ./../../../assets/pandoc/md2pdf.sh;
  };

  md2pdfLabels =
    if lang == "fr" then
      {
        plain = "Markdown vers PDF";
        big = "Markdown vers PDF (grand)";
        tablet = "Markdown vers PDF (tablette)";
        done = "PDF créé";
        failed = "Échec de la conversion";
      }
    else
      {
        plain = "Markdown to PDF";
        big = "Markdown to PDF (big)";
        tablet = "Markdown to PDF (tablet)";
        done = "PDF created";
        failed = "Conversion failed";
      };

  # Nautilus runs its scripts without a terminal: the outcome goes to a
  # desktop notification. Selected files arrive as arguments, relative to the
  # viewed folder, which is the working directory.
  md2pdfNautilus = flags: {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      if log="$(${getExe md2pdf} ${flags} "$@" 2>&1)"; then
        ${getExe' pkgs.libnotify "notify-send"} --app-name=md2pdf "${md2pdfLabels.done}" "$log"
      else
        ${getExe' pkgs.libnotify "notify-send"} --app-name=md2pdf --icon=dialog-error "${md2pdfLabels.failed}" "$log"
      fi
    '';
  };
in
{
  # Installed by the office package list.
  options.darkone.home.office.md2pdf = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    default = md2pdf;
    description = "`md2pdf` command, installed by the office package list.";
  };

  config = mkIf cfg.enable {

    # Installs pandoc wrapped with `--defaults`. Without an engine, a bare
    # `pandoc doc.md -o doc.pdf` looks for the absent `pdflatex`.
    programs.pandoc = mkIf cfg.enablePandoc {
      enable = true;
      defaults = {
        pdf-engine = pandocEngine;
        metadata-files = [ "${pandocMetadata}" ];
      };
    };

    # Right click > Scripts. GNOME only: Nautilus is its file manager.
    xdg.dataFile = mkIf (cfg.enablePandoc && osConfig.darkone.graphic.gnome.enable) {
      "nautilus/scripts/${md2pdfLabels.plain}" = md2pdfNautilus "";
      "nautilus/scripts/${md2pdfLabels.big}" = md2pdfNautilus "--big";
      "nautilus/scripts/${md2pdfLabels.tablet}" = md2pdfNautilus "--tablet";
    };
  };
}
