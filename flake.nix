{
  description = "da-moon/flakes — single aggregated entrypoint re-exporting per-subdir packages and Home Manager modules";

  # Each tool under this repo is its own self-contained flake (consumed
  # historically as `git+…/flakes.git?dir=<tool>`). This root flake pulls those
  # subdir flakes in and re-exports their outputs under one surface, so a
  # downstream flake needs a SINGLE input
  # (`url = "git+https://github.com/da-moon/flakes.git"`) instead of one per tool.
  #
  # NOTE: inputs reference the subdirs via `git+…?dir=<tool>` (absolute, fetchable)
  # rather than relative `path:./<tool>` — relative path inputs are not resolvable
  # in *fetched* flakes on Nix < 2.26, which silently breaks remote consumers.
  # All subdir flakes share the same two inputs (nixpkgs-unstable + flake-utils),
  # so we `follows` them onto this flake's copies — collapsing what would be ~21
  # duplicate nixpkgs nodes in a consumer's lock down to one.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    claude-code = { url = "git+https://github.com/da-moon/flakes.git?dir=claude-code"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    codex = { url = "git+https://github.com/da-moon/flakes.git?dir=codex"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    dd-cli = { url = "git+https://github.com/da-moon/flakes.git?dir=dd-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    beads = { url = "git+https://github.com/da-moon/flakes.git?dir=beads"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    kimi-cli = { url = "git+https://github.com/da-moon/flakes.git?dir=kimi-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    rtk = { url = "git+https://github.com/da-moon/flakes.git?dir=rtk"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    xurl = { url = "git+https://github.com/da-moon/flakes.git?dir=xurl"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    gsd-2 = { url = "git+https://github.com/da-moon/flakes.git?dir=gsd-2"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    hunk = { url = "git+https://github.com/da-moon/flakes.git?dir=hunk"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    askii = { url = "git+https://github.com/da-moon/flakes.git?dir=askii"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    markdown-magic = { url = "git+https://github.com/da-moon/flakes.git?dir=markdown-magic"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    parallel-web-tools = { url = "git+https://github.com/da-moon/flakes.git?dir=parallel-web-tools"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    nothing-ever-happens = { url = "git+https://github.com/da-moon/flakes.git?dir=nothing-ever-happens"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    elio = { url = "git+https://github.com/da-moon/flakes.git?dir=elio"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };

    # Optional tools — wired through so they resolve via dm when a consumer
    # uncomments them; not referenced by default.
    obscura = { url = "git+https://github.com/da-moon/flakes.git?dir=obscura"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    evolver = { url = "git+https://github.com/da-moon/flakes.git?dir=evolver"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    context-mode = { url = "git+https://github.com/da-moon/flakes.git?dir=context-mode"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    code-review-graph = { url = "git+https://github.com/da-moon/flakes.git?dir=code-review-graph"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    opennews-mcp = { url = "git+https://github.com/da-moon/flakes.git?dir=opennews-mcp"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    gemini-cli = { url = "git+https://github.com/da-moon/flakes.git?dir=gemini-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    goose-cli = { url = "git+https://github.com/da-moon/flakes.git?dir=goose-cli"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
    command-code = { url = "git+https://github.com/da-moon/flakes.git?dir=command-code"; inputs = { nixpkgs.follows = "nixpkgs"; flake-utils.follows = "flake-utils"; }; };
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
        "obscura" = { flake = "obscura"; attr = "obscura"; };
        "evolver" = { flake = "evolver"; attr = "evolver"; };
        "context-mode" = { flake = "context-mode"; attr = "context-mode"; };
        "code-review-graph" = { flake = "code-review-graph"; attr = "code-review-graph"; };
        "opennews-mcp" = { flake = "opennews-mcp"; attr = "opennews-mcp"; };
        "gemini-cli" = { flake = "gemini-cli"; attr = "gemini-cli"; };
        "goose-cli" = { flake = "goose-cli"; attr = "goose-cli"; };
        "command-code" = { flake = "command-code"; attr = "command-code"; };
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
