# Home-manager module for memlawb.
#
# - Installs the `memlawb` CLI, wrapped with the configured client environment
#   (so `memlawb push/pull` and the `memlawb mcp` stdio server work out of the
#   box — point any MCP client at the binary).
# - Optionally runs the crypto-blind memlawb server as a systemd user service
#   (`programs.memlawb.server.enable = true`, Linux only).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.memlawb;

  wrappedPackage = import ../lib/wrap-client.nix {
    inherit pkgs;
    package = cfg.package;
    inherit (cfg) client;
  };

  # Server environment, rendered from the typed options. Anything left null
  # falls back to the upstream defaults baked into src/config.ts; secrets are
  # expected through cfg.server.environmentFile.
  serverEnv = [
    "PORT=${toString cfg.server.port}"
    "STORE=${cfg.server.store}"
    "DATA_DIR=${cfg.server.dataDir}"
    "ALLOW_UNAUTHENTICATED=${lib.boolToString cfg.server.allowUnauthenticated}"
    "MAX_ENTRY_BYTES=${toString cfg.server.limits.maxEntryBytes}"
    "MAX_ENTRIES_PER_NAMESPACE=${toString cfg.server.limits.maxEntriesPerNamespace}"
    "MAX_NAMESPACE_BYTES=${toString cfg.server.limits.maxNamespaceBytes}"
    "MAX_NAMESPACES_PER_OWNER=${toString cfg.server.limits.maxNamespacesPerOwner}"
    "MAX_OWNER_BYTES=${toString cfg.server.limits.maxOwnerBytes}"
    "MAX_BODY_BYTES=${toString cfg.server.limits.maxBodyBytes}"
    "RATE_LIMIT_PER_MINUTE=${toString cfg.server.rateLimit.perMinute}"
    "RATE_LIMIT_BURST=${toString cfg.server.rateLimit.burst}"
  ]
  ++ lib.optionals (cfg.server.store == "s3") (
    [ "S3_REGION=${cfg.server.s3.region}" ]
    ++ lib.optional (cfg.server.s3.bucket != null) "S3_BUCKET=${cfg.server.s3.bucket}"
    ++ lib.optional (cfg.server.s3.endpoint != null) "S3_ENDPOINT=${cfg.server.s3.endpoint}"
    ++ lib.optional (cfg.server.s3.accessKeyId != null) "S3_ACCESS_KEY_ID=${cfg.server.s3.accessKeyId}"
    ++ lib.optional (
      cfg.server.s3.secretAccessKey != null
    ) "S3_SECRET_ACCESS_KEY=${cfg.server.s3.secretAccessKey}"
  )
  ++ lib.optional (cfg.server.supabase.url != null) "MEMLAWB_SUPABASE_URL=${cfg.server.supabase.url}"
  ++ lib.optional (
    cfg.server.supabase.secretKey != null
  ) "MEMLAWB_SUPABASE_SECRET_KEY=${cfg.server.supabase.secretKey}"
  ++ lib.optional (cfg.server.staticApiKeys != null) "STATIC_API_KEYS=${cfg.server.staticApiKeys}";

  storeNote = field: ''
    programs.memlawb.${field} is stored in the world-readable Nix store.
    Prefer the corresponding environmentFile option for real secrets.
  '';
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.server.enable -> pkgs.stdenv.hostPlatform.isLinux;
        message = "programs.memlawb.server runs as a systemd user service and is only supported on Linux.";
      }
      {
        assertion =
          cfg.server.enable
          -> cfg.server.store == "s3"
          -> (cfg.server.s3.bucket != null && cfg.server.s3.endpoint != null);
        message = "programs.memlawb.server: s3.bucket and s3.endpoint are required when store = \"s3\".";
      }
    ];

    warnings =
      lib.optional (cfg.client.passphrase != null) (storeNote "client.passphrase")
      ++ lib.optional (cfg.client.apiKey != null) (storeNote "client.apiKey")
      ++ lib.optional (cfg.server.staticApiKeys != null) (storeNote "server.staticApiKeys")
      ++ lib.optional (cfg.server.supabase.secretKey != null) (storeNote "server.supabase.secretKey")
      ++ lib.optional (cfg.server.s3.secretAccessKey != null) (storeNote "server.s3.secretAccessKey")
      ++
        lib.optional
          (
            cfg.server.enable
            && !cfg.server.allowUnauthenticated
            && cfg.server.staticApiKeys == null
            && cfg.server.supabase.url == null
            && cfg.server.environmentFile == null
          )
          ''
            programs.memlawb.server: authentication is required but no
            credential source is configured (staticApiKeys, supabase, or an
            environmentFile providing one); the server will reject every
            request.
          '';

    home.packages = [ wrappedPackage ];

    # HM defines the systemd user options on every platform; the
    # assertPlatform assertion above keeps the service itself Linux-only.
    systemd.user.services.memlawb = lib.mkIf cfg.server.enable {
      Unit = {
        Description = "memlawb zero-knowledge agent memory server";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "${cfg.package}/bin/memlawb serve";
        Environment = serverEnv;
        EnvironmentFile = lib.optional (cfg.server.environmentFile != null) cfg.server.environmentFile;
        Restart = "on-failure";
        RestartSec = "5";
      }
      // lib.optionalAttrs (cfg.server.store == "fs") {
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.server.dataDir}";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
