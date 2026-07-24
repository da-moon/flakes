# Typed options for superfile's config.toml and hotkeys.toml.
#
# Option names mirror the upstream TOML keys 1:1 (snake_case, no mapping
# layer) so https://superfile.dev documentation applies directly. Every
# default matches the default config shipped with superfile v1.6.0, i.e.
# enabling the module with no extra settings reproduces upstream's
# default configuration.
{ lib, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  mkBoolOption = default: description:
    mkOption { type = types.bool; inherit default description; };

  # Border glyphs must be exactly one terminal cell wide; that cannot be
  # checked reliably in Nix (cell width != string length), so this is only
  # documented, not enforced.
  mkBorderOption = default:
    mkOption {
      type = types.str;
      inherit default;
      description = "Border glyph; must be exactly one terminal cell wide (use ' ' for borderless).";
    };

  # Upstream requires every action to have at least one binding and the
  # first element to be non-empty ('' elements are placeholder "unset"
  # slots). The list type enforces the former; the latter is asserted in
  # home-manager.nix.
  mkHotkeyOption = default: description:
    mkOption {
      type = types.nonEmptyListOf types.str;
      inherit default description;
    };
in
{
  options.programs.superfile = {
    enable = mkEnableOption "superfile terminal file manager";

    package = mkOption {
      type = types.package;
      description = "The superfile package to use.";
    };

    # config.toml scalar keys, in upstream file order. `open_with` maps to
    # the [open_with] table and is always serialized last (see
    # superfile-lib.nix).
    settings = {
      editor = mkOption {
        type = types.str;
        default = "";
        description = ''
          Editor files are opened with; whitespace-split into command +
          arguments (e.g. "code --wait", no quoting). Empty string uses
          $EDITOR, falling back to nano.
        '';
      };

      dir_editor = mkOption {
        type = types.str;
        default = "";
        description = ''
          Editor directories are opened with; same splitting semantics as
          `editor`. Empty string falls back to vi.
        '';
      };

      auto_check_update = mkBoolOption true ''
        Check for a new superfile release on exit (max once per 24h, via
        the GitHub API). Consider setting this to false on Nix, where
        updates come from the flake.
      '';

      cd_on_quit = mkBoolOption false ''
        On quit, write `cd '<lastdir>'` to the lastdir file for a shell
        wrapper to source.
      '';

      default_open_file_preview = mkBoolOption true ''
        Open the file preview panel automatically when selection-hovering
        over a file.
      '';

      show_image_preview = mkBoolOption true ''
        Render image previews (kitty/sixel/ANSI depending on the
        terminal).
      '';

      show_panel_footer_info = mkBoolOption true ''
        Show the extra file-info footer in the file panel.
      '';

      default_directory = mkOption {
        type = types.str;
        default = ".";
        description = ''
          Initial path of the first file panel; understands `.`, `..` and
          `~`.
        '';
      };

      file_size_use_si = mkBoolOption false ''
        File size units: true = SI/1000 (kB, MB), false = IEC/1024 (KiB,
        MiB).
      '';

      default_sort_type = mkOption {
        type = types.ints.between 0 4;
        default = 0;
        description = ''
          Default file panel sort: 0 = Name, 1 = Size, 2 = Date Modified,
          3 = Type, 4 = Natural. Directories always sort on top.
        '';
      };

      sort_order_reversed = mkBoolOption false ''
        Default sort order: false = ascending, true = descending.
      '';

      case_sensitive_sort = mkBoolOption false ''
        Case-sensitive name sort ("B" before "a" when true).
      '';

      shell_close_on_success = mkBoolOption false ''
        Close the in-app shell prompt after a successful command.
      '';

      page_scroll_size = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Lines scrolled per PgUp/PgDown; 0 = full page.";
      };

      debug = mkBoolOption false "Debug mode (verbose logging).";

      ignore_missing_fields = mkBoolOption false ''
        Silence warnings about missing config fields.
      '';

      file_panel_extra_columns = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = ''
          Extra columns in the file panel besides the name column; 0
          disables the feature.
        '';
      };

      file_panel_name_percent = mkOption {
        type = types.ints.between 25 100;
        default = 50;
        description = ''
          Percent of the file panel width allocated to the name column
          (25-100).
        '';
      };

      theme = mkOption {
        type = types.str;
        default = "catppuccin-mocha";
        description = ''
          Color theme: a built-in theme name, or the name of a
          `theme/<name>.toml` file in the superfile config dir.
        '';
      };

      code_previewer = mkOption {
        type = types.enum [ "" "bat" ];
        default = "";
        description = ''
          Syntax highlighting engine for code preview: "" = builtin
          chroma, "bat" = external bat (requires bat or batcat in PATH).
        '';
      };

      nerdfont = mkBoolOption true "Use Nerd Font glyphs for icons.";

      show_select_icons = mkBoolOption true ''
        Checkbox icons in select mode; requires nerdfont = true.
      '';

      transparent_background = mkBoolOption false ''
        Enable background transparency (the terminal must support it).
      '';

      file_preview_width = mkOption {
        type = types.either (types.enum [ 0 ]) (types.ints.between 2 10);
        default = 0;
        description = ''
          Preview panel width as 1/n of the total width (2-10); 0 = same
          width as the file panel.
        '';
      };

      enable_file_preview_border = mkBoolOption false ''
        Draw a border around the file preview panel.
      '';

      sidebar_width = mkOption {
        type = types.either (types.enum [ 0 ]) (types.ints.between 5 20);
        default = 20;
        description = "Sidebar width (5-20); 0 hides the sidebar.";
      };

      sidebar_sections = mkOption {
        type = types.listOf (types.enum [ "home" "pinned" "disks" ]);
        default = [ "home" "pinned" "disks" ];
        description = "Which sidebar sections to show, and in what order.";
      };

      border_top = mkBorderOption "─";
      border_bottom = mkBorderOption "─";
      border_left = mkBorderOption "│";
      border_right = mkBorderOption "│";
      border_top_left = mkBorderOption "╭";
      border_top_right = mkBorderOption "╮";
      border_bottom_left = mkBorderOption "╰";
      border_bottom_right = mkBorderOption "╯";
      border_middle_left = mkBorderOption "├";
      border_middle_right = mkBorderOption "┤";

      metadata = mkBoolOption false ''
        Detailed metadata panel; requires exiftool in PATH.
      '';

      enable_md5_checksum = mkBoolOption false ''
        MD5 checksum in the metadata panel (pure Go, no external
        dependency; reads the whole file, so slow on large files).
      '';

      zoxide_support = mkBoolOption false ''
        zoxide smart-jump modal on `z`; requires zoxide in PATH.
      '';

      open_with = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          png = "feh";
          pdf = "zathura";
        };
        description = ''
          Per-extension opener commands (the [open_with] table): keys are
          lowercase extensions without the dot, values are bare executable
          names. Values are not word-split — the file path is appended as
          the only argument. Always serialized as the last table of
          config.toml.
        '';
      };
    };

    # hotkeys.toml keys, grouped like upstream's file. Defaults pad with ''
    # placeholder slots exactly like the shipped default.
    hotkeys = {
      # Global hotkeys (must be unique among themselves).
      confirm = mkHotkeyOption [ "enter" "right" "l" ] "Open/enter the selected item (dir or file).";
      cd_quit = mkHotkeyOption [ "Q" "" ] "Quit and (with cd_on_quit) cd the parent shell to the current dir.";
      quit = mkHotkeyOption [ "q" "esc" ] "Quit superfile / close modal.";
      list_down = mkHotkeyOption [ "down" "j" ] "Move cursor down.";
      list_up = mkHotkeyOption [ "up" "k" ] "Move cursor up.";
      page_down = mkHotkeyOption [ "pgdown" "" ] "Page down (see settings.page_scroll_size).";
      page_up = mkHotkeyOption [ "pgup" "" ] "Page up.";
      close_file_panel = mkHotkeyOption [ "w" "" ] "Close the focused file panel.";
      create_new_file_panel = mkHotkeyOption [ "n" "" ] "Open a new file panel.";
      next_file_panel = mkHotkeyOption [ "tab" "L" ] "Focus next file panel.";
      open_sort_options_menu = mkHotkeyOption [ "o" "" ] "Open the sort-options modal.";
      pinned_directory = mkHotkeyOption [ "P" "" ] "Pin/unpin the current dir in the sidebar.";
      previous_file_panel = mkHotkeyOption [ "shift+left" "H" ] "Focus previous file panel.";
      split_file_panel = mkHotkeyOption [ "N" "" ] "Split panel view.";
      toggle_file_preview_panel = mkHotkeyOption [ "f" "" ] "Show/hide the preview panel.";
      toggle_reverse_sort = mkHotkeyOption [ "R" "" ] "Reverse sort order.";
      focus_on_metadata = mkHotkeyOption [ "m" "" ] "Focus the metadata panel.";
      focus_on_process_bar = mkHotkeyOption [ "p" "" ] "Focus the process bar.";
      focus_on_sidebar = mkHotkeyOption [ "s" "" ] "Focus the sidebar.";
      file_panel_item_create = mkHotkeyOption [ "ctrl+n" "" ] "Create new file/directory (typing mode).";
      file_panel_item_rename = mkHotkeyOption [ "ctrl+r" "" ] "Rename selected item.";
      copy_items = mkHotkeyOption [ "ctrl+c" "" ] "Copy selected items to the clipboard.";
      cut_items = mkHotkeyOption [ "ctrl+x" "" ] "Cut selected items.";
      delete_items = mkHotkeyOption [ "ctrl+d" "delete" "" ] "Delete to trash (with confirm modal).";
      paste_items = mkHotkeyOption [ "ctrl+v" "ctrl+w" "" ] "Paste clipboard items into the current panel.";
      permanently_delete_items = mkHotkeyOption [ "D" "" ] "Permanently delete (bypasses trash, confirm modal).";
      compress_file = mkHotkeyOption [ "ctrl+a" "" ] "Compress selected items into a zip archive.";
      extract_file = mkHotkeyOption [ "ctrl+e" "" ] "Extract selected archive.";
      open_current_directory_with_editor = mkHotkeyOption [ "E" "" ] "Open current dir with dir_editor.";
      open_file_with_editor = mkHotkeyOption [ "e" "" ] "Open selected file with editor.";
      change_panel_mode = mkHotkeyOption [ "v" "" ] "Toggle between normal and select mode.";
      copy_path = mkHotkeyOption [ "ctrl+p" "" ] "Copy selected item's path to the OS clipboard.";
      copy_present_working_directory = mkHotkeyOption [ "c" "" ] "Copy current dir path to the OS clipboard.";
      open_command_line = mkHotkeyOption [ ":" "" ] "Open the shell-command input.";
      open_help_menu = mkHotkeyOption [ "?" "" ] "Open the help/hotkey menu.";
      open_spf_prompt = mkHotkeyOption [ ">" "" ] "Open the superfile prompt (spf-mode commands).";
      open_zoxide = mkHotkeyOption [ "z" "" ] "Open the zoxide jump modal (needs settings.zoxide_support = true).";
      toggle_dot_file = mkHotkeyOption [ "." "" ] "Show/hide dotfiles.";
      toggle_footer = mkHotkeyOption [ "F" "" ] "Show/hide the footer + process bar.";

      # Typing hotkeys (override all others).
      confirm_typing = mkHotkeyOption [ "enter" "" ] "Confirm an input field.";
      cancel_typing = mkHotkeyOption [ "ctrl+c" "esc" ] "Cancel an input field.";

      # Mode-specific hotkeys (may conflict across modes, but not with
      # global hotkeys).
      parent_directory = mkHotkeyOption [ "h" "left" "backspace" ] "(Normal mode) Go to parent directory.";
      search_bar = mkHotkeyOption [ "/" "" ] "(Normal mode) Open the search bar.";
      file_panel_select_mode_items_select_down = mkHotkeyOption [ "shift+down" "J" ] "(Select mode) Extend selection down.";
      file_panel_select_mode_items_select_up = mkHotkeyOption [ "shift+up" "K" ] "(Select mode) Extend selection up.";
      file_panel_select_all_items = mkHotkeyOption [ "A" "" ] "(Select mode) Select all items.";
    };
  };
}
