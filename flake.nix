{
  description = "da-moon/flakes — single aggregated entrypoint re-exporting per-subdir packages and Home Manager modules";

  # Each tool under this repo is its own self-contained flake (consumed
  # historically as `git+…/flakes.git?dir=<tool>`). This root flake pulls those
  # subdir flakes in as relative `path:./<tool>` inputs and re-exports their
  # outputs under one surface, so a downstream flake needs a SINGLE input
  # (`url = "git+https://github.com/da-moon/flakes.git"`) instead of one per tool.
  #
  # All subdir flakes share the same two inputs (nixpkgs-unstable + flake-utils),
  # so we `follows` them onto this flake's copies — collapsing what used to be
  # ~14 duplicate nixpkgs nodes in a consumer's lock down to one.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    claude-code = { url = "path:./claude-code"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    codex = { url = "path:./codex"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    dd-cli = { url = "path:./dd-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    beads = { url = "path:./beads"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    kimi-cli = { url = "path:./kimi-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    rtk = { url = "path:./rtk"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    xurl = { url = "path:./xurl"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    gsd-2 = { url = "path:./gsd-2"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    hunk = { url = "path:./hunk"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    askii = { url = "path:./askii"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    markdown-magic = { url = "path:./markdown-magic"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    parallel-web-tools = { url = "path:./parallel-web-tools"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    nothing-ever-happens = { url = "path:./nothing-ever-happens"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    elio = { url = "path:./elio"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
  };

  outputs =
    { self, nixpkgs, flake-utils, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # consumer-facing package name -> { flake = <input>; attr = <attr in that flake's packages.<system>>; }
      pkgMap = {
        "claude-code" = { flake = "claude-code"; attr = "claude-code"; };
        "codex" = { flake = "codex"; attr = "codex"; };
        "dd-cli" = { flake = "dd-cli"; attr = "dd-cli"; };
        "beads" = { flake = "beads"; attr = "beads"; };
        "kimi-cli" = { flake = "kimi-cli"; attr = "kimi-cli"; };
        "rtk" = { flake = "rtk"; attr = "rtk"; };
        "xurl" = { flake = "xurl"; attr = "xurl"; };
        "gsd-2" = { flake = "gsd-2"; attr = "gsd-2"; };
        "hunk" = { flake = "hunk"; attr = "hunk"; };
        "askii" = { flake = "askii"; attr = "askii"; };
        "markdown-magic" = { flake = "markdown-magic"; attr = "markdown-magic"; };
        "parallel-cli" = { flake = "parallel-web-tools"; attr = "parallel-cli"; };
        "nothing-ever-happens" = { flake = "nothing-ever-happens"; attr = "nothing-ever-happens"; };
      };

      hasPkg = system: m:
        ((inputs.${m.flake}.packages or { }) ? ${system})
        && ((inputs.${m.flake}.packages.${system} or { }) ? ${m.attr});
    in
    flake-utils.lib.eachDefaultSystem (
      system: {
        # Only re-export entries whose source flake actually provides the attr
        # for this system, so an unsupported platform is skipped, not an error.
        packages = lib.mapAttrs
          (_: m: inputs.${m.flake}.packages.${system}.${m.attr})
          (lib.filterAttrs (_: m: hasPkg system m) pkgMap);
      }
    )
    // {
      # System-agnostic outputs (Home Manager modules) live outside eachDefaultSystem.
      homeManagerModules = {
        elio = inputs.elio.homeManagerModules.default;
        nothing-ever-happens = inputs.nothing-ever-happens.homeManagerModules.default;
      };
    };
}
