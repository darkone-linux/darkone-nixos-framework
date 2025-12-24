# Home profile for advanced users (computer scientists, developers, admins).

{
  lib,
  pkgs,
  config,
  osConfig,
  network,
  users,
  inputs,
  ...
}:

let
  cfg = config.darkone.home.advanced;
  graphic = osConfig.darkone.graphic.gnome.enable;
  hasBorg = osConfig.darkone.service.borg.enable;
  hasRestic = osConfig.darkone.service.restic.enable;

  # Nix administrator host (additional tools)
  onAdminHost = osConfig.darkone.admin.nix.enable;

  # Last colmena release
  inherit (inputs.colmena.packages.${pkgs.stdenv.hostPlatform.system}) colmena;

  # Extraction of current user from host configuration
  user = users.${config.home.username};
in
{
  options = {
    darkone.home.advanced.enable = lib.mkEnableOption "Enable advanced user features";
    darkone.home.advanced.enableTools = lib.mkEnableOption "Various tools for advanced users";
    darkone.home.advanced.enableAdmin = lib.mkEnableOption "Enable administrator features (network, os tools)";
    darkone.home.advanced.enableNixAdmin = lib.mkEnableOption "Enable nix administration features";
    darkone.home.advanced.enableDeveloper = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable tools for developer";
    };
    darkone.home.advanced.enableEssentials = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Frequently used tools";
    };
  };

  config = lib.mkIf cfg.enable {

    #============================================================================
    # ENVIRONMENT
    #============================================================================

    home.sessionVariables = {
      SOPS_AGE_KEY_FILE = "/etc/nixos/usr/secrets/infra.key";
      MANPAGER = "sh -c 'col -bx | bat -l man -p'"; # bat
      MANROFFOPT = "-c"; # bat
      EDITOR = "vim";
      VISUAL = "vim";
    };

    #============================================================================
    # PACKAGES
    #============================================================================

    home.packages = with pkgs; [
      #findutils # locate
      #powerline
      #powerline-fonts
      (lib.mkIf (graphic && (cfg.enableDeveloper || cfg.enableAdmin)) vscode) # TODO: module
      (lib.mkIf (graphic && cfg.enableAdmin) filezilla)
      (lib.mkIf (graphic && cfg.enableAdmin) gparted)
      (lib.mkIf (graphic && cfg.enableNixAdmin) dconf-editor) # GSettings editor
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableAdmin) impression) # Create bootable drives
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableAdmin) sysprof) # System-wide profiler
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableDeveloper) commit) # Commit message editor
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableDeveloper) eyedropper) # Pick and format colors
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableDeveloper) forge-sparks) # Get Git forges notifications
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableDeveloper) lorem) # Generate placeholder text
      (lib.mkIf (graphic && cfg.enableTools && cfg.enableNixAdmin) bustle) # Graphical D-Bus message analyser and profiler
      (lib.mkIf (graphic && cfg.enableTools) apostrophe) # Distraction free Markdown editor
      (lib.mkIf (graphic && cfg.enableTools) collision) # Check hashes for your files
      (lib.mkIf (graphic && cfg.enableTools) gnome-connections) # VNC / RDP Client
      (lib.mkIf (graphic && cfg.enableTools) gnome-logs)
      (lib.mkIf (graphic && cfg.enableTools) meld) # Diff tool
      (lib.mkIf (graphic && cfg.enableTools) resources) # Monitor your system resources and processes
      (lib.mkIf (graphic && cfg.enableTools) textpieces) # Swiss knife of text processing
      (lib.mkIf (hasBorg && cfg.enableAdmin) borgbackup)
      (lib.mkIf (hasBorg && graphic && cfg.enableAdmin) vorta) # Borg client
      (lib.mkIf (hasRestic && cfg.enableAdmin) restic) # Already in nixos configuration...
      (lib.mkIf (hasRestic && cfg.enableAdmin) restic-browser)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) age)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) colmena)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) deadnix)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) just)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) moreutils) # sponge
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) nixfmt-rfc-style)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) php84)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) php84Packages.composer)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) sops)
      (lib.mkIf (onAdminHost && cfg.enableNixAdmin) statix)
      (lib.mkIf cfg.enableAdmin bridge-utils)
      (lib.mkIf cfg.enableAdmin ccrypt)
      (lib.mkIf cfg.enableAdmin dig)
      (lib.mkIf cfg.enableAdmin dos2unix)
      (lib.mkIf cfg.enableAdmin gnupg)
      (lib.mkIf cfg.enableAdmin inetutils)
      (lib.mkIf cfg.enableAdmin iptraf-ng)
      (lib.mkIf cfg.enableAdmin iw)
      (lib.mkIf cfg.enableAdmin lsof)
      (lib.mkIf cfg.enableAdmin nettools)
      (lib.mkIf cfg.enableAdmin nmap)
      (lib.mkIf cfg.enableAdmin ntp)
      (lib.mkIf cfg.enableAdmin ntpstat)
      (lib.mkIf cfg.enableAdmin pciutils) # lspci pcilmr setpci
      (lib.mkIf cfg.enableAdmin pinentry-curses)
      (lib.mkIf cfg.enableAdmin psmisc) # killall, pstree, pslog, fuser...
      (lib.mkIf cfg.enableAdmin rmlint)
      (lib.mkIf cfg.enableAdmin strace)
      (lib.mkIf cfg.enableAdmin tcpdump)
      (lib.mkIf cfg.enableAdmin wirelesstools) # ifrename iwconfig iwevent iwgetid iwlist iwpriv iwspy
      (lib.mkIf cfg.enableEssentials cpufetch)
      (lib.mkIf cfg.enableEssentials duf)
      (lib.mkIf cfg.enableEssentials gawk)
      (lib.mkIf cfg.enableEssentials htop)
      (lib.mkIf cfg.enableEssentials jq)
      (lib.mkIf cfg.enableEssentials less)
      (lib.mkIf cfg.enableEssentials microfetch)
      (lib.mkIf cfg.enableEssentials nodejs_24) # CoC, required for vim
      (lib.mkIf cfg.enableEssentials rename)
      (lib.mkIf cfg.enableEssentials rsync)
      (lib.mkIf cfg.enableEssentials tree)
      (lib.mkIf cfg.enableEssentials unzip)
      (lib.mkIf cfg.enableEssentials wget)
      (lib.mkIf cfg.enableEssentials wipe)
      (lib.mkIf cfg.enableEssentials zellij)
      (lib.mkIf cfg.enableEssentials zip)
      (lib.mkIf cfg.enableNixAdmin mkpasswd)
      (lib.mkIf cfg.enableNixAdmin wakeonlan)
      (lib.mkIf cfg.enableNixAdmin yq)
      (lib.mkIf cfg.enableTools fastfetch)
      (lib.mkIf cfg.enableTools presenterm)
      (lib.mkIf cfg.enableTools pv)
      (lib.mkIf cfg.enableTools ranger)
    ];

    #============================================================================
    # FEATURES
    #============================================================================

    programs.fzf = {
      enable = lib.mkDefault cfg.enableEssentials;
      enableZshIntegration = true;
      defaultCommand = "rg --files --hidden";
      defaultOptions = [
        "--no-mouse"
        "--info=inline-right"
      ];
    };

    # z command to replace cd
    programs.zoxide = {
      enable = lib.mkDefault cfg.enableEssentials;
      enableZshIntegration = true;
    };

    # ls alternative
    programs.eza = {
      enable = lib.mkDefault cfg.enableEssentials;
      enableZshIntegration = false;
    };

    # cat alternative + man pages
    programs.bat.enable = lib.mkDefault cfg.enableEssentials;

    # rg command -> recursive grep
    programs.ripgrep.enable = lib.mkDefault cfg.enableEssentials;

    # Custom btop
    programs.btop = {
      enable = lib.mkDefault cfg.enableEssentials;
      settings = {
        proc_per_core = true;
        update_ms = 1000;
      };
    };

    # Zed editor
    darkone.home.zed.enable = lib.mkDefault graphic;

    # Terminal file manager
    programs.yazi = {
      enable = lib.mkDefault cfg.enableTools;
      enableZshIntegration = true;
    };

    #============================================================================
    # GIT
    #============================================================================

    # Full featured git
    programs.git = {
      enable = true;
      settings = {
        user = {
          name = "${user.name}";
          email =
            if (builtins.hasAttr "email" user) then
              "${user.email}"
            else
              "${config.home.username}@${network.domain}";
        };
        alias = {
          amend = "!git add . && git commit --amend --no-edit";
          pf = "!git push --force";
        };
        core = {
          editor = "vim";
          whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
        };
        delta = {
          enable = true;
          options = {
            "navigate" = true;
          };
        };
        diff.tool = "vimdiff";
        web.browser = "firefox";
        push.default = "tracking";
        push.autoSetupRemote = true;
        pull.rebase = false;
        init.defaultBranch = "main";
        color.ui = true;
      };
      ignores = [
        "*~"
        "*.swp"
        ".vscode"
        ".idea"
      ];

      # Undefined but required from 02/2025
      signing.format = "ssh";
    };

    #============================================================================
    # VIM
    #============================================================================

    # Conf complète : https://github.com/jagajaga/my_configs/blob/master/.nixpkgs/vimrc.nix
    programs.vim = {
      enable = true;
      defaultEditor = true; # Define EDITOR envvar

      # Vim plugins
      plugins = with pkgs.vimPlugins; [
        LazyVim
        coc-fzf
        coc-git
        coc-html
        coc-json
        coc-markdownlint
        coc-nvim
        coc-pairs
        coc-sh
        coc-yaml
        ctrlp-vim
        emmet-vim
        fzf-vim
        fzfWrapper
        gruvbox
        lightline-gruvbox-vim
        lightline-vim
        mini-completion
        nerdtree
        nerdtree-git-plugin
        vim-gitgutter
        vim-just
        vim-lastplace
        vim-nix
        vim-polyglot
      ];

      settings = {
        ignorecase = true;
      };

      extraConfig = ''
        set mouse=a

        " Set utf8 as standard encoding and en_US as the standard language
        set encoding=utf8

        " Use Unix as the standard file type
        set ffs=unix,dos,mac

        " Enable syntax highlighting
        syntax enable

        " Set 7 lines to the cursor - when moving vertically using j/k
        set so=7

        " 1 tab == 2 spaces
        set shiftwidth=2
        set tabstop=2
        set shiftround                  "Round spaces to nearest shiftwidth multiple
        set nojoinspaces                "Don't convert spaces to tabs

        set ai "Auto indent
        set si "Smart indent
        set wrap "Wrap lines

        " Visual mode pressing * or # searches for the current selection
        " Super useful! From an idea by Michael Naumann
        vnoremap <silent> * :call VisualSelection('f')<CR>
        vnoremap <silent> # :call VisualSelection('b')<CR>

        " Always show the status line
        set laststatus=2

        " Format the status line
        "set statusline=\ %{HasPaste()}%F%m%r%h\ %w\ \ CWD:\ %r%{getcwd()}%h\ \ \ Line:\ %l

        " Gruvbox (theme)
        set termguicolors
        set background=dark
        let g:gruvbox_italic=1
        colorscheme gruvbox

        " Airline options
        "let g:airline#extensions#tabline#enabled = 1
        "let g:airline_powerline_fonts = 1

        let g:lightline = {
        \ 'colorscheme': 'jellybeans',
        \ 'active': {
        \   'left': [ [ 'mode', 'paste' ],
        \             [ 'gitbranch', 'readonly', 'filename', 'modified' ] ]
        \ },
        \ 'component_function': {
        \   'gitbranch': 'FugitiveHead'
        \ },
        \ }

        " Line numbers
        set number relativenumber

        " Highlight cursor line
        hi CursorLineNr term=bold guifg=#fabd2f guibg=NONE
        set cursorline
        set cursorlineopt=number

        " Git gutter colors
        highlight clear SignColumn
        highlight GitGutterAdd ctermfg=142 ctermbg=237 guifg=#b8bb26 guibg=NONE
        highlight GitGutterDelete ctermfg=167 ctermbg=237 guifg=#fb4934 guibg=NONE
        highlight GitGutterChange ctermfg=108 ctermbg=237 guifg=#8ec07c guibg=NONE

        " Use system clipboard
        set clipboard=unnamedplus

        " Start NERDTree when Vim is started without file arguments.
        autocmd StdinReadPre * let s:std_in=1
        autocmd VimEnter * if argc() == 0 && !exists('s:std_in') | NERDTree | endif

        " Start NERDTree when Vim starts with a directory argument.
        autocmd StdinReadPre * let s:std_in=1
        autocmd VimEnter * if argc() == 1 && isdirectory(argv()[0]) && !exists('s:std_in') |
            \ execute 'NERDTree' argv()[0] | wincmd p | enew | execute 'cd '.argv()[0] | endif

        " Exit Vim if NERDTree is the only window remaining in the only tab.
        autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | call feedkeys(":quit\<CR>:\<BS>") | endif

        " Nix format
        nnoremap <F2> :%!nixfmt -s<cr>

        " Map <Space> to / (search) and <Ctrl>+<Space> to ? (backwards search)
        map <space> /
        map <C-space> ?

        " Nerd tree
        nnoremap <leader>n :NERDTreeFocus<CR>
        nnoremap <C-n> :NERDTree<CR>
        nnoremap <C-t> :NERDTreeToggle<CR>
        nnoremap <C-f> :NERDTreeFind<CR>

        " Configuration CoC
        set hidden
        set nobackup
        set nowritebackup
        set cmdheight=2
        set updatetime=300
        set shortmess+=c
        set signcolumn=yes

        " Navigation
        nmap <silent> gd <Plug>(coc-definition)
        nmap <silent> gy <Plug>(coc-type-definition)
        nmap <silent> gi <Plug>(coc-implementation)
        nmap <silent> gr <Plug>(coc-references)

        " Auto-completion with Tab (TODO: voir comment améliorer)
        "inoremap <silent><expr> <TAB>
        "  \ pumvisible() ? "\<C-n>" :
        "  \ <SID>check_back_space() ? "\<TAB>" :
        "  \ coc#refresh()
        "inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
        inoremap <Tab> <Tab>

        function! s:check_back_space() abort
          let col = col('.') - 1
          return !col || getline('.')[col - 1]  =~# '\s'
        endfunction

        " Formatting du code
        xmap <leader>f  <Plug>(coc-format-selected)
        nmap <leader>f  <Plug>(coc-format-selected)
      '';
    };

    #============================================================================
    # SECURITY (WIP)
    #============================================================================

    #  programs.gpg.enable = true;
    #  services.gpg-agent = {
    #    enable = true;
    #    defaultCacheTtl = 34560000;
    #    maxCacheTtl = 34560000;
    #    enableSshSupport = true;
    #    enableZshIntegration = true;
    #    pinentryPackage = pkgs.pinentry-curses;
    #  };
  };
}
