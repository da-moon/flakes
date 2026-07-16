# Shared hook submodule type (does not need pkgs).
{ lib }:
let
  inherit (lib)
    mkOption
    types
    ;
in
types.submodule {
  options = {
    name = mkOption {
      type = types.str;
      description = ''
        Unique identifier for this hook. It becomes the hook filename
        (<name>.sh) and is used to idempotently upsert the entry in
        settings.json.
      '';
    };

    event = mkOption {
      type = types.str;
      default = "PreToolUse";
      description = ''
        The Command Code hook event this hook belongs to (e.g.
        PreToolUse, PostToolUse, Stop, SessionStart).
      '';
    };

    matcher = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional matcher string (e.g. "SHELL", "write", "read"). When
        null, the hook runs for every tool in the event.
      '';
    };

    timeout = mkOption {
      type = types.int;
      default = 10;
      description = ''
        Hook timeout in seconds. Command Code defaults to 30 and allows
        up to 600.
      '';
    };

    script = mkOption {
      type = types.either types.str types.path;
      description = ''
        Shell script contents (string) or path to a script file. The
        script will be packaged into the Nix store and referenced from
        settings.json.
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
