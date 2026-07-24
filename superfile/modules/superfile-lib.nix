# Shared helpers for rendering superfile's TOML config files.
{ pkgs }:
let
  tomlFormat = pkgs.formats.toml { };
in
{
  # config.toml: all scalar keys first, then the [open_with] table.
  #
  # TOML cannot close tables, so [open_with] MUST be the last table in the
  # file — any scalar serialized after its header gets parsed into the
  # table and corrupts the config. pkgs.formats.toml sorts attrsets
  # alphabetically, which would strand every key sorting after "open_with"
  # (page_scroll_size, shell_close_on_success, sidebar_*, sort_*, theme,
  # transparent_background, zoxide_support) inside the table. So generate
  # the scalar document and the open_with table as separate TOML texts and
  # concatenate, open_with last. An empty open_with still gets its bare
  # header, matching upstream's shipped default file exactly.
  mkSuperfileConfig =
    { cfg }:
    let
      scalars = builtins.removeAttrs cfg.settings [ "open_with" ];
      scalarsToml = tomlFormat.generate "superfile-config-scalars.toml" scalars;
      openWithToml =
        if cfg.settings.open_with == { } then
          pkgs.writeText "superfile-config-open-with.toml" "[open_with]\n"
        else
          tomlFormat.generate "superfile-config-open-with.toml" {
            inherit (cfg.settings) open_with;
          };
    in
    pkgs.runCommand "superfile-config.toml" { } ''
      cat ${scalarsToml} > $out
      printf '\n' >> $out
      cat ${openWithToml} >> $out
    '';

  # hotkeys.toml: flat key = [bindings] pairs only, so key order is
  # irrelevant and alphabetical sorting by the generator is harmless.
  mkSuperfileHotkeys =
    { cfg }:
    tomlFormat.generate "superfile-hotkeys.toml" cfg.hotkeys;
}
