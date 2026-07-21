# Shared client wrapper for the `memlawb` binary (CLI + stdio MCP server).
#
# Bakes the non-secret MEMLAWB_* client environment into the binary so the CLI
# and `memlawb mcp` work no matter how they are launched (shell, agent, GUI).
# Values configured in Nix win over the process environment and over the
# optional environment file.
#
# Secrets (MEMLAWB_PASSPHRASE, MEMLAWB_API_KEY) should NOT be set through the
# `client.passphrase` / `client.apiKey` attributes — those land in the
# world-readable Nix store. Prefer `client.environmentFile`: a file sourced at
# runtime (e.g. ~/.secrets/memlawb) that may define them.
{
  pkgs,
  package,
  client,
}:
let
  inherit (pkgs) lib;

  # Sourced first, so the --set flags below take precedence over it.
  envFileArgs = lib.optionals (client.environmentFile != null) [
    "--run"
    ''
      if [ -f ${lib.escapeShellArg client.environmentFile} ]; then
        set -a
        . ${lib.escapeShellArg client.environmentFile}
        set +a
      fi
    ''
  ];

  setArgs = [
    "--set"
    "MEMLAWB_NAMESPACE"
    client.namespace
    "--set"
    "MEMLAWB_SCAN"
    client.scan
  ]
  ++ lib.optionals (client.url != null) [
    "--set"
    "MEMLAWB_URL"
    client.url
  ]
  ++ lib.optionals (client.apiKey != null) [
    "--set"
    "MEMLAWB_API_KEY"
    client.apiKey
  ]
  ++ lib.optionals (client.passphrase != null) [
    "--set"
    "MEMLAWB_PASSPHRASE"
    client.passphrase
  ];
in
pkgs.symlinkJoin {
  name = "${lib.getName package}-client";
  paths = [ package ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/memlawb" ${lib.escapeShellArgs (envFileArgs ++ setArgs)}
  '';
}
