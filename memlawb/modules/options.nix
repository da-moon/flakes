# Options for programs.memlawb — the values mirror the upstream .env.example
# (https://github.com/Gitlawb/memlawb) one-to-one, managed in Nix style.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkPackageOption
    types
    ;

  secretStoreNote = ''
    Note: values set here are stored in the world-readable Nix store. Prefer
    the corresponding `environmentFile` option for real secrets.
  '';
in
{
  options.programs.memlawb = {
    enable = mkEnableOption "memlawb — zero-knowledge agent memory (CLI, stdio MCP server, and sync client)";

    package = mkPackageOption pkgs "memlawb" { };

    client = {
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://memory.example.com";
        description = ''
          Base URL of the memlawb server the CLI and MCP server talk to
          (MEMLAWB_URL). `null` keeps the upstream default
          `http://localhost:8080`, which matches the bundled server service.
        '';
      };

      namespace = mkOption {
        type = types.str;
        default = "user:me";
        example = "project:flakes";
        description = ''
          Default namespace the CLI and MCP server read/write when a call
          omits one (MEMLAWB_NAMESPACE).
        '';
      };

      scan = mkOption {
        type = types.enum [
          "block"
          "warn"
          "off"
        ];
        default = "block";
        description = ''
          Secret-scan policy applied to plaintext before encryption
          (MEMLAWB_SCAN): `block` refuses to upload detected secrets, `warn`
          logs and continues, `off` disables scanning.
        '';
      };

      apiKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Bearer token for servers that require authentication
          (MEMLAWB_API_KEY). Omit for an `allowUnauthenticated` self-host.
          ${secretStoreNote}
        '';
      };

      passphrase = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Passphrase the client derives the zero-knowledge encryption key
          from (MEMLAWB_PASSPHRASE). Required for `push`/`pull`/MCP reads and
          writes; losing it means losing access to your memory.
          ${secretStoreNote}
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/home/alice/.secrets/memlawb";
        description = ''
          File sourced at runtime by the wrapped `memlawb` binary before any
          configured values are applied. Intended for secrets such as
          MEMLAWB_PASSPHRASE and MEMLAWB_API_KEY. Values configured in Nix
          take precedence over values from this file.
        '';
      };
    };

    server = {
      enable = mkEnableOption "the memlawb server as a systemd user service (Linux only)";

      port = mkOption {
        type = types.port;
        default = 8080;
        description = "Port the server listens on (PORT).";
      };

      store = mkOption {
        type = types.enum [
          "fs"
          "s3"
        ];
        default = "fs";
        description = ''
          Storage driver (STORE): `fs` filesystem (zero-config, best for
          self-host) or `s3` S3-compatible object storage.
        '';
      };

      dataDir = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/.local/share/memlawb";
        defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.local/share/memlawb"'';
        description = "Directory the fs driver stores ciphertext in (DATA_DIR).";
      };

      s3 = {
        bucket = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "S3 bucket name (S3_BUCKET). Required when `store` is `s3`.";
        };

        endpoint = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://fly.storage.tigris.dev";
          description = "S3 endpoint URL (S3_ENDPOINT). Required when `store` is `s3`.";
        };

        region = mkOption {
          type = types.str;
          default = "auto";
          description = "S3 region (S3_REGION).";
        };

        accessKeyId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            S3 access key id (S3_ACCESS_KEY_ID). ${secretStoreNote}
          '';
        };

        secretAccessKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            S3 secret access key (S3_SECRET_ACCESS_KEY). ${secretStoreNote}
          '';
        };
      };

      allowUnauthenticated = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true, no API key is required and everything maps to a single
          owner (ALLOW_UNAUTHENTICATED). Use for single-user self-host only;
          NEVER set true on a shared deployment.
        '';
      };

      supabase = {
        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Hosted auth via the shared gitlawb Supabase, API-key lookup table
            (MEMLAWB_SUPABASE_URL).
          '';
        };

        secretKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Supabase secret key (MEMLAWB_SUPABASE_SECRET_KEY). ${secretStoreNote}
          '';
        };
      };

      staticApiKeys = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "alice:mk_live_aaa,bob:mk_live_bbb";
        description = ''
          Simple static keys for self-host without Supabase: comma-separated
          "owner:key" pairs (STATIC_API_KEYS). ${secretStoreNote}
        '';
      };

      limits = {
        maxEntryBytes = mkOption {
          type = types.ints.positive;
          default = 250000;
          description = "Maximum size of a single entry (MAX_ENTRY_BYTES).";
        };

        maxEntriesPerNamespace = mkOption {
          type = types.ints.positive;
          default = 2000;
          description = "Maximum entries per namespace (MAX_ENTRIES_PER_NAMESPACE).";
        };

        maxNamespaceBytes = mkOption {
          type = types.ints.positive;
          default = 10000000;
          description = "Total ciphertext bytes per namespace (MAX_NAMESPACE_BYTES).";
        };

        maxNamespacesPerOwner = mkOption {
          type = types.ints.positive;
          default = 50;
          description = ''
            Per-account namespace cap (MAX_NAMESPACES_PER_OWNER). Not applied
            to the self-host `local` owner.
          '';
        };

        maxOwnerBytes = mkOption {
          type = types.ints.positive;
          default = 50000000;
          description = ''
            Per-account aggregate ciphertext cap (MAX_OWNER_BYTES). Not
            applied to the self-host `local` owner.
          '';
        };

        maxBodyBytes = mkOption {
          type = types.ints.positive;
          default = 8000000;
          description = "Whole-PUT body cap (MAX_BODY_BYTES).";
        };
      };

      rateLimit = {
        perMinute = mkOption {
          type = types.ints.unsigned;
          default = 120;
          description = ''
            Per-owner token-bucket refill rate (RATE_LIMIT_PER_MINUTE).
            Set to 0 to disable rate limiting.
          '';
        };

        burst = mkOption {
          type = types.ints.unsigned;
          default = 240;
          description = "Per-owner token-bucket burst size (RATE_LIMIT_BURST).";
        };
      };

      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/home/alice/.secrets/memlawb-server";
        description = ''
          EnvironmentFile passed to the systemd user service. Intended for
          secrets such as STATIC_API_KEYS, MEMLAWB_SUPABASE_SECRET_KEY, and
          S3_SECRET_ACCESS_KEY so they stay out of the Nix store.
        '';
      };
    };
  };
}
