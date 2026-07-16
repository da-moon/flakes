# Shared hook submodule type for kimi-cli (does not need pkgs).
{ lib }:
let
  inherit (lib)
    mkOption
    types
    ;
  hookEvents = (import ./config-schema.nix { inherit lib; }).hookEvents;
in
types.submodule {
  options = {
    name = mkOption {
      type = types.str;
      description = ''
        Unique identifier for this hook. It becomes the hook filename
        (<name>.sh) and is used to idempotently upsert the entry in
        config.toml.
      '';
    };

    event = mkOption {
      type = types.enum hookEvents;
      default = "PreToolUse";
      description = ''
        The Kimi hook event (stage) this hook belongs to. One of the 16
        documented events: ${builtins.concatStringsSep ", " hookEvents}.
      '';
    };

    matcher = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional regular expression to filter event targets (e.g. "Bash",
        "startup|resume"). When null, the hook runs for every target in the
        event.
      '';
    };

    timeout = mkOption {
      type = types.ints.between 1 600;
      default = 30;
      description = ''
        Hook timeout in seconds (documented range 1-600, upstream default 30).
      '';
    };

    script = mkOption {
      type = types.either types.str types.path;
      description = ''
        Shell script contents (string) or path to a script file. The
        script will be packaged into the Nix store and referenced from
        config.toml.
      '';
    };

    runtimeInputs = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Packages that should be available on PATH when the hook runs.
      '';
    };
  };
}
