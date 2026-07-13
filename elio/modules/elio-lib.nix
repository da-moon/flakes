# Shared helpers for rendering elio's TOML config/theme files.
{ pkgs }:
let
  lib = pkgs.lib;

  # Recursively drop null-valued attributes and collapse empty attrsets to null.
  # Lists are preserved as-is (including empty lists, which elio uses to unbind
  # keys), but their attribute elements are compacted.
  compact = value:
    if builtins.isAttrs value then
      let
        cleaned = lib.filterAttrs (k: v: v != null) (lib.mapAttrs (k: v: compact v) value);
      in
      if cleaned == { } then null else cleaned
    else if builtins.isList value then
      map compact value
    else
      value;

  # Build the TOML attrset from typed options + extraSettings.
  buildSettings = cfg:
    let
      section = name: value:
        let
          c = compact value;
        in
        lib.optionalAttrs (c != null && c != { }) { ${name} = c; };
    in
    section "ui" cfg.ui
    // section "places" cfg.places
    // section "goto" cfg.goto
    // section "open" cfg.open
    // section "layout" cfg.layout
    // section "keys" cfg.keys
    // cfg.extraSettings;

  tomlFormat = pkgs.formats.toml { };
in
{
  mkElioConfig =
    { cfg }:
    let
      settings = buildSettings cfg;
    in
    if settings == { } then null else tomlFormat.generate "elio-config.toml" settings;

  mkElioTheme =
    { cfg }:
    if cfg.theme == { } then null else tomlFormat.generate "elio-theme.toml" cfg.theme;

  hasSettings = cfg: buildSettings cfg != { };
}
