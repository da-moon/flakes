{ lib }:
let
  inherit (lib)
    mkOption
    optionalAttrs
    types
    ;

  numberType = types.either types.int types.float;
  nonNegativeNumberType = types.addCheck numberType (value: value >= 0);
  pathStringType = types.either types.str types.path;

  jsonValueType = types.nullOr (
    types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      (types.listOf jsonValueType)
      (types.attrsOf jsonValueType)
    ]
  );
  jsonObjectType = types.attrsOf jsonValueType;

  languageValues = [
    "csharp"
    "python"
    "rust"
    "java"
    "kotlin"
    "typescript"
    "go"
    "ruby"
    "dart"
    "cpp"
    "cpp_ccls"
    "php"
    "r"
    "perl"
    "clojure"
    "elixir"
    "elm"
    "terraform"
    "swift"
    "bash"
    "crystal"
    "cue"
    "zig"
    "lua"
    "luau"
    "nix"
    "erlang"
    "ocaml"
    "al"
    "fsharp"
    "rego"
    "scala"
    "julia"
    "fortran"
    "haskell"
    "haxe"
    "lean4"
    "groovy"
    "vue"
    "svelte"
    "powershell"
    "pascal"
    "matlab"
    "msl"
    "bsl"
    "ada"
    "gdscript"
    "qml"
    "typescript_vts"
    "python_jedi"
    "python_ty"
    "python_pyrefly"
    "csharp_omnisharp"
    "ruby_solargraph"
    "php_phpactor"
    "php_phpantom"
    "markdown"
    "latex"
    "yaml"
    "json"
    "toml"
    "hlsl"
    "systemverilog"
    "solidity"
    "ansible"
    "html"
    "scss"
    "angular"
  ];

  builtinContexts = [
    "agent"
    "antigravity"
    "chatgpt"
    "claude-code"
    "codebuddy"
    "codex"
    "copilot-cli"
    "desktop-app"
    "ide"
    "jb-ai-assistant"
    "jb-copilot-plugin"
    "junie"
    "oaicompat-agent"
    "vscode"
  ];

  builtinModes = [
    "benchmark"
    "editing"
    "interactive"
    "no-memories"
    "no-onboarding"
    "onboarding"
    "one-shot"
    "planning"
    "query-projects"
  ];

  globalDefaults = {
    extraSettings = { };
    languageBackend = "LSP";
    lineEnding = "native";
    guiLogWindow = false;
    webDashboard = true;
    webDashboardOpenOnLaunch = true;
    webDashboardInterface = null;
    webDashboardListenAddress = "127.0.0.1";
    webDashboardTrustedHosts = [
      "127.0.0.1"
      "localhost"
    ];
    jetbrainsPluginServerAddress = "127.0.0.1";
    jetbrainsLaunchCommand = null;
    trustedProjectPathPatterns = [ ];
    logLevel = 20;
    traceLspCommunication = false;
    lsSpecificSettings = { };
    ignoredPaths = [ ];
    readOnlyMemoryPatterns = [ ];
    ignoredMemoryPatterns = [ ];
    toolTimeout = 240;
    excludedTools = [ ];
    includedOptionalTools = [ ];
    fixedTools = [ ];
    baseModes = [
      "interactive"
      "editing"
    ];
    defaultModes = null;
    defaultMaxToolAnswerChars = 150000;
    tokenCountEstimator = "CHAR_COUNT";
    symbolInfoBudget = 10;
    projectSerenaFolderLocation = "$projectDir/.serena";
    projects = [ ];
  };

  projectDefaults = {
    extraSettings = { };
    projectName = "project_name";
    languages = [ "python" ];
    encoding = "utf-8";
    lineEnding = null;
    languageBackend = null;
    ignoreAllFilesInGitignore = true;
    lsSpecificSettings = { };
    activationCommand = null;
    activationCommandTimeout = 180;
    lsAdditionalWorkspaceFolders = [ ];
    lsWorkspaceFolders = [ "." ];
    ignoredPaths = [ ];
    readOnly = false;
    excludedTools = [ ];
    includedOptionalTools = [ ];
    fixedTools = [ ];
    defaultModes = null;
    addedModes = null;
    initialPrompt = "";
    symbolInfoBudget = null;
    readOnlyMemoryPatterns = [ ];
    ignoredMemoryPatterns = [ ];
  };

  contextDefaults = {
    extraSettings = { };
    description = "";
    excludedTools = [ ];
    includedOptionalTools = [ ];
    fixedTools = [ ];
    toolDescriptionOverrides = { };
    singleProject = false;
    structuredToolOutput = null;
  };

  modeDefaults = {
    extraSettings = { };
    description = "";
    excludedTools = [ ];
    includedOptionalTools = [ ];
    fixedTools = [ ];
  };

  globalFieldMappings = {
    languageBackend = "language_backend";
    lineEnding = "line_ending";
    guiLogWindow = "gui_log_window";
    webDashboard = "web_dashboard";
    webDashboardOpenOnLaunch = "web_dashboard_open_on_launch";
    webDashboardInterface = "web_dashboard_interface";
    webDashboardListenAddress = "web_dashboard_listen_address";
    webDashboardTrustedHosts = "web_dashboard_trusted_hosts";
    jetbrainsPluginServerAddress = "jetbrains_plugin_server_address";
    jetbrainsLaunchCommand = "jetbrains_launch_command";
    trustedProjectPathPatterns = "trusted_project_path_patterns";
    logLevel = "log_level";
    traceLspCommunication = "trace_lsp_communication";
    lsSpecificSettings = "ls_specific_settings";
    ignoredPaths = "ignored_paths";
    readOnlyMemoryPatterns = "read_only_memory_patterns";
    ignoredMemoryPatterns = "ignored_memory_patterns";
    toolTimeout = "tool_timeout";
    excludedTools = "excluded_tools";
    includedOptionalTools = "included_optional_tools";
    fixedTools = "fixed_tools";
    baseModes = "base_modes";
    defaultModes = "default_modes";
    defaultMaxToolAnswerChars = "default_max_tool_answer_chars";
    tokenCountEstimator = "token_count_estimator";
    symbolInfoBudget = "symbol_info_budget";
    projectSerenaFolderLocation = "project_serena_folder_location";
    projects = "projects";
  };

  projectFieldMappings = {
    projectName = "project_name";
    languages = "languages";
    encoding = "encoding";
    lineEnding = "line_ending";
    languageBackend = "language_backend";
    ignoreAllFilesInGitignore = "ignore_all_files_in_gitignore";
    lsSpecificSettings = "ls_specific_settings";
    activationCommand = "activation_command";
    activationCommandTimeout = "activation_command_timeout";
    lsAdditionalWorkspaceFolders = "ls_additional_workspace_folders";
    lsWorkspaceFolders = "ls_workspace_folders";
    ignoredPaths = "ignored_paths";
    readOnly = "read_only";
    excludedTools = "excluded_tools";
    includedOptionalTools = "included_optional_tools";
    fixedTools = "fixed_tools";
    defaultModes = "default_modes";
    addedModes = "added_modes";
    initialPrompt = "initial_prompt";
    symbolInfoBudget = "symbol_info_budget";
    readOnlyMemoryPatterns = "read_only_memory_patterns";
    ignoredMemoryPatterns = "ignored_memory_patterns";
  };

  contextFieldMappings = {
    name = "name";
    prompt = "prompt";
    description = "description";
    excludedTools = "excluded_tools";
    includedOptionalTools = "included_optional_tools";
    fixedTools = "fixed_tools";
    toolDescriptionOverrides = "tool_description_overrides";
    singleProject = "single_project";
    structuredToolOutput = "structured_tool_output";
  };

  modeFieldMappings = {
    name = "name";
    prompt = "prompt";
    description = "description";
    excludedTools = "excluded_tools";
    includedOptionalTools = "included_optional_tools";
    fixedTools = "fixed_tools";
  };

  promptFieldMappings = {
    connectionPrompt = "connection_prompt";
    systemPrompt = "system_prompt";
    ccSystemPromptOverride = "cc_system_prompt_override";
    infoJetBrainsDebugRepl = "info_jet_brains_debug_repl";
    onboardingPrompt = "onboarding_prompt";
  };

  lsLanguageMappings = {
    ada = "ada";
    al = "al";
    angular = "angular";
    ansible = "ansible";
    bash = "bash";
    bsl = "bsl";
    clojure = "clojure";
    cpp = "cpp";
    cppCcls = "cpp_ccls";
    csharp = "csharp";
    csharpOmnisharp = "csharp_omnisharp";
    cue = "cue";
    dart = "dart";
    elixir = "elixir";
    elm = "elm";
    fortran = "fortran";
    fsharp = "fsharp";
    gdscript = "gdscript";
    go = "go";
    groovy = "groovy";
    haxe = "haxe";
    hlsl = "hlsl";
    html = "html";
    java = "java";
    json = "json";
    kotlin = "kotlin";
    lean4 = "lean4";
    lua = "lua";
    luau = "luau";
    markdown = "markdown";
    matlab = "matlab";
    pascal = "pascal";
    perl = "perl";
    php = "php";
    phpPhpactor = "php_phpactor";
    phpPhpantom = "php_phpantom";
    powershell = "powershell";
    python = "python";
    pythonPyrefly = "python_pyrefly";
    pythonTy = "python_ty";
    ruby = "ruby";
    rust = "rust";
    scala = "scala";
    scss = "scss";
    solidity = "solidity";
    svelte = "svelte";
    systemverilog = "systemverilog";
    terraform = "terraform";
    toml = "toml";
    typescript = "typescript";
    typescriptVts = "typescript_vts";
    vue = "vue";
    yaml = "yaml";
  };

  lsFieldMappings = {
    ada = {
      lsPath = "ls_path";
      alsVersion = "als_version";
    };
    al.alExtensionVersion = "al_extension_version";
    angular = {
      angularLanguageServerVersion = "angular_language_server_version";
      angularLanguageServiceVersion = "angular_language_service_version";
      typescriptVersion = "typescript_version";
      typescriptLanguageServerVersion = "typescript_language_server_version";
      npmRegistry = "npm_registry";
    };
    ansible = {
      lsPath = "ls_path";
      ansibleLanguageServerVersion = "ansible_language_server_version";
      npmRegistry = "npm_registry";
      ansiblePath = "ansible_path";
      ansibleSettings = "ansible_settings";
      lintEnabled = "lint_enabled";
      lintPath = "lint_path";
      pythonInterpreterPath = "python_interpreter_path";
      pythonActivationScript = "python_activation_script";
    };
    bash = {
      lsPath = "ls_path";
      bashLanguageServerVersion = "bash_language_server_version";
      npmRegistry = "npm_registry";
    };
    bsl = {
      lsPath = "ls_path";
      bslLsVersion = "bsl_ls_version";
    };
    clojure = {
      lsPath = "ls_path";
      clojureLspVersion = "clojure_lsp_version";
      sourcePaths = "source_paths";
      configEdnPath = "config_edn_path";
    };
    cpp = {
      lsPath = "ls_path";
      compileCommandsDir = "compile_commands_dir";
      clangdVersion = "clangd_version";
    };
    cppCcls.lsPath = "ls_path";
    csharp = {
      csharpLanguageServerVersion = "csharp_language_server_version";
      runtimeDependencies = "runtime_dependencies";
    };
    csharpOmnisharp = {
      omnisharpVersion = "omnisharp_version";
      razorOmnisharpVersion = "razor_omnisharp_version";
    };
    cue = {
      lsPath = "ls_path";
      cueVersion = "cue_version";
    };
    dart.dartSdkVersion = "dart_sdk_version";
    elixir.expertVersion = "expert_version";
    elm = {
      elmLanguageServerVersion = "elm_language_server_version";
      elmCompilerVersion = "elm_compiler_version";
      npmRegistry = "npm_registry";
    };
    fortran = {
      lsPath = "ls_path";
      fortlsVersion = "fortls_version";
    };
    fsharp.fsautocompleteVersion = "fsautocomplete_version";
    gdscript = {
      port = "port";
      requestTimeout = "request_timeout";
    };
    go.goplsSettings = "gopls_settings";
    groovy = {
      lsJarPath = "ls_jar_path";
      lsJavaHomePath = "ls_java_home_path";
      lsJarOptions = "ls_jar_options";
      vscodeJavaVersion = "vscode_java_version";
    };
    haxe = {
      lsPath = "ls_path";
      version = "version";
      buildFile = "buildFile";
      haxePath = "haxePath";
      renameSourceFolders = "renameSourceFolders";
    };
    hlsl = {
      lsPath = "ls_path";
      version = "version";
    };
    html = {
      lsPath = "ls_path";
      vscodeLangserversPackage = "vscode_langservers_package";
      vscodeLangserversVersion = "vscode_langservers_version";
      npmRegistry = "npm_registry";
    };
    java = {
      jdtlsPath = "jdtls_path";
      lombokPath = "lombok_path";
      javaHome = "java_home";
      mavenUserSettings = "maven_user_settings";
      gradleUserHome = "gradle_user_home";
      gradleWrapperEnabled = "gradle_wrapper_enabled";
      gradleJavaHome = "gradle_java_home";
      useSystemJavaHome = "use_system_java_home";
      runtimes = "runtimes";
      gradleVersion = "gradle_version";
      vscodeJavaVersion = "vscode_java_version";
      intellicodeVersion = "intellicode_version";
      lombokShowGenerated = "lombok_show_generated";
      jdtlsXmx = "jdtls_xmx";
      jdtlsXms = "jdtls_xms";
      intellicodeXmx = "intellicode_xmx";
      intellicodeXms = "intellicode_xms";
    };
    json = {
      lsPath = "ls_path";
      jsonLanguageServerVersion = "json_language_server_version";
      npmRegistry = "npm_registry";
    };
    kotlin = {
      lsPath = "ls_path";
      kotlinLspVersion = "kotlin_lsp_version";
      jvmOptions = "jvm_options";
    };
    lean4.lsPath = "ls_path";
    lua.luaLanguageServerVersion = "lua_language_server_version";
    luau = {
      lsPath = "ls_path";
      luauLspVersion = "luau_lsp_version";
      platform = "platform";
      robloxSecurityLevel = "roblox_security_level";
    };
    markdown = {
      lsPath = "ls_path";
      marksmanVersion = "marksman_version";
    };
    matlab = {
      matlabPath = "matlab_path";
      matlabExtensionVersion = "matlab_extension_version";
    };
    pascal = {
      paslsVersion = "pasls_version";
      pp = "pp";
      fpcdir = "fpcdir";
      lazarusdir = "lazarusdir";
      fpcTarget = "fpc_target";
      fpcTargetCpu = "fpc_target_cpu";
    };
    perl = {
      fileFilter = "file_filter";
      ignoreDirs = "ignore_dirs";
    };
    php = {
      lsPath = "ls_path";
      intelephenseVersion = "intelephense_version";
      npmRegistry = "npm_registry";
      ignoreVendor = "ignore_vendor";
      maxFileSize = "maxFileSize";
      maxMemory = "maxMemory";
      fileFilter = "file_filter";
    };
    phpPhpactor = {
      lsPath = "ls_path";
      phpactorVersion = "phpactor_version";
      ignoreVendor = "ignore_vendor";
    };
    phpPhpantom = {
      ignoreVendor = "ignore_vendor";
      phpantomVersion = "phpantom_version";
    };
    powershell = {
      psesVersion = "pses_version";
      psscriptanalyzerVersion = "psscriptanalyzer_version";
    };
    python = {
      lsPath = "ls_path";
      pyrightVersion = "pyright_version";
    };
    pythonPyrefly = {
      indexingMode = "indexing_mode";
      pyreflyVersion = "pyrefly_version";
      workspaceIndexingLimit = "workspace_indexing_limit";
    };
    pythonTy = {
      lsPath = "ls_path";
      tyVersion = "ty_version";
    };
    ruby.rubyLspVersion = "ruby_lsp_version";
    rust.lsPath = "ls_path";
    scala = {
      metalsVersion = "metals_version";
      clientName = "client_name";
      onStaleLock = "on_stale_lock";
      logMultiInstanceNotice = "log_multi_instance_notice";
    };
    scss = {
      lsPath = "ls_path";
      someSassVersion = "some_sass_version";
      npmRegistry = "npm_registry";
    };
    solidity = {
      lsPath = "ls_path";
      solidityLanguageServerVersion = "solidity_language_server_version";
      forgeVersion = "forge_version";
      npmRegistry = "npm_registry";
    };
    svelte = {
      lsPath = "ls_path";
      svelteLanguageServerVersion = "svelte_language_server_version";
      typescriptVersion = "typescript_version";
      typescriptLanguageServerVersion = "typescript_language_server_version";
      typescriptSveltePluginVersion = "typescript_svelte_plugin_version";
      npmRegistry = "npm_registry";
      indexingTimeout = "indexing_timeout";
      initializationOptionsConfiguration = "initialization_options_configuration";
    };
    systemverilog = {
      lsPath = "ls_path";
      veribleVersion = "verible_version";
    };
    terraform.terraformLsVersion = "terraform_ls_version";
    toml = {
      lsPath = "ls_path";
      taploVersion = "taplo_version";
    };
    typescript = {
      lsPath = "ls_path";
      typescriptVersion = "typescript_version";
      typescriptLanguageServerVersion = "typescript_language_server_version";
      npmRegistry = "npm_registry";
      indexingTimeout = "indexing_timeout";
      serverReadyTimeout = "server_ready_timeout";
    };
    typescriptVts = {
      vtslsVersion = "vtsls_version";
      npmRegistry = "npm_registry";
      initializationOptions = "initialization_options";
    };
    vue = {
      vueLanguageServerVersion = "vue_language_server_version";
      npmRegistry = "npm_registry";
    };
    yaml = {
      lsPath = "ls_path";
      yamlLanguageServerVersion = "yaml_language_server_version";
      npmRegistry = "npm_registry";
    };
  };

  runtimeDependencyFieldMappings = {
    id = "id";
    platformId = "platform_id";
    url = "url";
    sha256 = "sha256";
    allowedHosts = "allowed_hosts";
    archiveType = "archive_type";
    binaryName = "binary_name";
    command = "command";
    packageName = "package_name";
    packageVersion = "package_version";
    extractPath = "extract_path";
    description = "description";
  };

  javaRuntimeFieldMappings = {
    name = "name";
    path = "path";
    default = "default";
    sources = "sources";
    javadoc = "javadoc";
  };

  mkStr =
    default: description:
    mkOption {
      type = types.str;
      inherit default description;
    };

  mkNullableStr =
    description:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit description;
    };

  mkBool =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
    };

  mkExtraSettingsOption =
    description:
    mkOption {
      type = jsonObjectType;
      default = { };
      inherit description;
    };

  mkLanguageOption =
    description: options:
    mkOption {
      type = types.nullOr (
        types.submodule {
          options = options // {
            extraSettings = mkExtraSettingsOption ''
              Additional upstream settings for this language-server implementation.
              Typed options take precedence when keys overlap.
            '';
          };
        }
      );
      default = null;
      inherit description;
    };

  lsPathOption = mkNullableStr "Path to a pre-installed language-server executable or server artifact.";
  npmRegistryOption = mkNullableStr "Alternative npm registry used by Serena's managed installation.";

  runtimeDependencyType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Runtime dependency identifier; C# normally uses CSharpLanguageServer.";
      };
      platformId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Platform selector for the dependency override, such as linux-x64 or any.";
      };
      url = mkNullableStr "Download URL.";
      sha256 = mkNullableStr "Expected SHA-256 checksum.";
      allowedHosts = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Hosts permitted while following download redirects.";
      };
      archiveType = mkNullableStr "Archive type understood by SolidLSP.";
      binaryName = mkNullableStr "Expected binary or DLL path within the extracted dependency.";
      command = mkOption {
        type = types.nullOr (types.either types.str (types.listOf types.str));
        default = null;
        description = "Installation command for command-backed dependencies.";
      };
      packageName = mkNullableStr "Package name.";
      packageVersion = mkNullableStr "Package version.";
      extractPath = mkNullableStr "Path within the archive to extract.";
      description = mkNullableStr "Human-readable dependency description.";
    };
  };

  javaRuntimeType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "JDT-LS execution-environment name, such as JavaSE-25; reusing JavaSE-21 overrides the bundled runtime.";
      };
      path = mkOption {
        type = types.str;
        description = "Existing JDK/JRE home directory registered for this runtime.";
      };
      default = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Whether JDT-LS treats this runtime as the default; null omits the flag.";
      };
      sources = mkNullableStr "Source archive path forwarded to JDT-LS; null omits it.";
      javadoc = mkNullableStr "Javadoc path forwarded to JDT-LS; null omits it.";
    };
  };

  lsSpecificSettingsOptions = {
    extraSettings = mkExtraSettingsOption ''
      Additional upstream ls_specific_settings entries, including future
      language implementations. Typed language entries take precedence when
      upstream language keys overlap.
    '';
    ada = mkLanguageOption "Ada Language Server settings." {
      lsPath = lsPathOption;
      alsVersion = mkStr "2026.2.202604091" "Ada Language Server release version.";
    };
    al = mkLanguageOption "AL language-server settings." {
      alExtensionVersion = mkStr "18.0.2242655" "Microsoft AL VS Code extension version.";
    };
    angular = mkLanguageOption "Angular multi-process language-server settings." {
      angularLanguageServerVersion = mkStr "21.2.10" "@angular/language-server version.";
      angularLanguageServiceVersion = mkStr "21.2.10" "@angular/language-service version.";
      typescriptVersion = mkStr "5.9.3" "TypeScript version.";
      typescriptLanguageServerVersion = mkStr "5.1.3" "typescript-language-server version.";
      npmRegistry = npmRegistryOption;
    };
    ansible = mkLanguageOption "Ansible language-server settings." {
      lsPath = lsPathOption;
      ansibleLanguageServerVersion = mkStr "1.2.3" "Ansible language-server version.";
      npmRegistry = npmRegistryOption;
      ansiblePath = mkStr "ansible" "Path or command used to invoke Ansible.";
      ansibleSettings = mkOption {
        type = types.nullOr jsonObjectType;
        default = null;
        description = "Full Ansible language-server settings merged over Serena defaults.";
      };
      lintEnabled = mkBool false "Enable ansible-lint integration.";
      lintPath = mkStr "ansible-lint" "Path or command used to invoke ansible-lint.";
      pythonInterpreterPath = mkStr "python3" "Python interpreter forwarded to the server.";
      pythonActivationScript = mkStr "" "Virtual-environment activation script.";
    };
    bash = mkLanguageOption "Bash language-server settings." {
      lsPath = lsPathOption;
      bashLanguageServerVersion = mkStr "5.6.0" "bash-language-server version.";
      npmRegistry = npmRegistryOption;
    };
    bsl = mkLanguageOption "BSL language-server settings." {
      lsPath = lsPathOption;
      bslLsVersion = mkStr "0.29.0" "bsl-language-server version.";
    };
    clojure = mkLanguageOption "Clojure language-server settings." {
      lsPath = lsPathOption;
      clojureLspVersion = mkStr "2026.02.20-16.08.58" "clojure-lsp version.";
      sourcePaths = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Explicit repository-relative source paths.";
      };
      configEdnPath = mkNullableStr "Path to a config.edn whose source paths Serena should read.";
    };
    cpp = mkLanguageOption "clangd settings." {
      lsPath = lsPathOption;
      compileCommandsDir = mkStr ".serena" "Directory for Serena's transformed compile_commands.json.";
      clangdVersion = mkStr "19.1.2" "clangd version.";
    };
    cppCcls = mkLanguageOption "ccls settings." { lsPath = lsPathOption; };
    csharp = mkLanguageOption "Roslyn C# language-server settings." {
      csharpLanguageServerVersion = mkStr "5.5.0-2.26078.4" "Roslyn language-server package version.";
      runtimeDependencies = mkOption {
        type = types.listOf runtimeDependencyType;
        default = [ ];
        description = "Runtime dependency overrides for Roslyn language-server packages.";
      };
    };
    csharpOmnisharp = mkLanguageOption "OmniSharp C# settings." {
      omnisharpVersion = mkStr "1.39.10" "OmniSharp version.";
      razorOmnisharpVersion = mkStr "7.0.0-preview.23363.1" "Razor OmniSharp plugin version.";
    };
    cue = mkLanguageOption "CUE language-server settings." {
      lsPath = lsPathOption;
      cueVersion = mkStr "v0.16.1" "CUE release version.";
    };
    dart = mkLanguageOption "Dart language-server settings." {
      dartSdkVersion = mkStr "3.7.1" "Dart SDK version.";
    };
    elixir = mkLanguageOption "Elixir Expert settings." {
      expertVersion = mkStr "v0.1.0-rc.6" "Expert release version.";
    };
    elm = mkLanguageOption "Elm language-server settings." {
      elmLanguageServerVersion = mkStr "2.8.0" "Elm language-server version.";
      elmCompilerVersion = mkStr "0.19.1-6" "Elm compiler npm package version.";
      npmRegistry = npmRegistryOption;
    };
    fortran = mkLanguageOption "Fortran language-server settings." {
      lsPath = lsPathOption;
      fortlsVersion = mkStr "3.2.2" "fortls version.";
    };
    fsharp = mkLanguageOption "F# language-server settings." {
      fsautocompleteVersion = mkStr "0.83.0" "FsAutoComplete version.";
    };
    gdscript = mkLanguageOption "Godot GDScript language-server settings." {
      port = mkOption {
        type = types.port;
        default = 6008;
        description = "Godot editor LSP TCP port.";
      };
      requestTimeout = mkOption {
        type = numberType;
        default = 30.0;
        description = "Godot LSP request timeout in seconds.";
      };
    };
    go = mkLanguageOption "gopls settings." {
      goplsSettings = mkOption {
        type = types.nullOr jsonObjectType;
        default = null;
        description = "JSON-compatible gopls initializationOptions.";
      };
    };
    groovy = mkLanguageOption "Groovy language-server settings." {
      lsJarPath = mkNullableStr "Required path to the Groovy Language Server JAR.";
      lsJavaHomePath = mkNullableStr "Java home used to launch the Groovy server.";
      lsJarOptions = mkStr "" "Additional shell-like options passed to the Groovy server JAR.";
      vscodeJavaVersion = mkStr "1.42.0-561" "Managed Java runtime bundle version.";
    };
    haxe = mkLanguageOption "Haxe language-server settings." {
      lsPath = lsPathOption;
      version = mkStr "2.34.2" "vshaxe extension version.";
      buildFile = mkNullableStr "Repository-relative HXML build file.";
      haxePath = mkNullableStr "Haxe compiler path.";
      renameSourceFolders = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Source folders used to scope rename operations.";
      };
    };
    hlsl = mkLanguageOption "HLSL language-server settings." {
      lsPath = lsPathOption;
      version = mkStr "1.3.1" "shader-language-server version.";
    };
    html = mkLanguageOption "HTML language-server settings." {
      lsPath = lsPathOption;
      vscodeLangserversPackage = mkStr "vscode-langservers-extracted" "npm package providing the HTML server.";
      vscodeLangserversVersion = mkStr "4.10.0" "HTML server npm package version.";
      npmRegistry = npmRegistryOption;
    };
    java = mkLanguageOption "Eclipse JDTLS settings." {
      jdtlsPath = mkNullableStr "Upstream JDTLS root; must be paired with lombokPath.";
      lombokPath = mkNullableStr "Lombok JAR; must be paired with jdtlsPath.";
      javaHome = mkNullableStr "JDK 21+ home for upstream JDTLS mode.";
      mavenUserSettings = mkNullableStr "Maven settings.xml path; omitted means auto-detect ~/.m2/settings.xml.";
      gradleUserHome = mkNullableStr "Gradle user home; omitted means auto-detect ~/.gradle.";
      gradleWrapperEnabled = mkBool false "Use the project's Gradle wrapper.";
      gradleJavaHome = mkNullableStr "JDK home used by Gradle.";
      useSystemJavaHome = mkBool false "Use the process JAVA_HOME for JDTLS.";
      runtimes = mkOption {
        type = types.listOf javaRuntimeType;
        default = [ ];
        description = "Extra JRE/JDK entries registered with JDT-LS via java.configuration.runtimes, for projects whose source/target level exceeds the JDK JDT-LS runs on.";
      };
      gradleVersion = mkStr "8.14.2" "Managed Gradle version.";
      vscodeJavaVersion = mkOption {
        type = types.enum [
          "1.42.0-561"
          "1.54.0-923"
        ];
        default = "1.54.0-923";
        description = "Pinned vscode-java bundle version supported by Serena v1.6.1.";
      };
      intellicodeVersion = mkStr "1.2.30" "IntelliCode extension version.";
      lombokShowGenerated = mkBool true "Show Lombok-generated symbols.";
      jdtlsXmx = mkStr "3G" "Maximum JDTLS JVM heap.";
      jdtlsXms = mkStr "100m" "Initial JDTLS JVM heap.";
      intellicodeXmx = mkStr "1G" "Maximum IntelliCode JVM heap.";
      intellicodeXms = mkStr "100m" "Initial IntelliCode JVM heap.";
    };
    json = mkLanguageOption "JSON language-server settings." {
      lsPath = lsPathOption;
      jsonLanguageServerVersion = mkStr "1.3.4" "vscode-json-languageserver version.";
      npmRegistry = npmRegistryOption;
    };
    kotlin = mkLanguageOption "Kotlin language-server settings." {
      lsPath = lsPathOption;
      kotlinLspVersion = mkStr "261.13587.0" "Kotlin language-server version.";
      jvmOptions = mkStr "-Xmx2G" "JAVA_TOOL_OPTIONS for the Kotlin server; empty disables JVM options.";
    };
    lean4 = mkLanguageOption "Lean 4 language-server settings." { lsPath = lsPathOption; };
    lua = mkLanguageOption "Lua language-server settings." {
      luaLanguageServerVersion = mkStr "3.15.0" "lua-language-server version.";
    };
    luau = mkLanguageOption "Luau language-server settings." {
      lsPath = lsPathOption;
      luauLspVersion = mkStr "1.63.0" "luau-lsp version.";
      platform = mkOption {
        type = types.enum [
          "roblox"
          "standard"
        ];
        default = "roblox";
        description = "Luau platform type.";
      };
      robloxSecurityLevel = mkOption {
        type = types.enum [
          "None"
          "PluginSecurity"
          "LocalUserSecurity"
          "RobloxScriptSecurity"
        ];
        default = "PluginSecurity";
        description = "Roblox security level used to filter API definitions.";
      };
    };
    markdown = mkLanguageOption "Marksman settings." {
      lsPath = lsPathOption;
      marksmanVersion = mkStr "2024-12-18" "Marksman release tag.";
    };
    matlab = mkLanguageOption "MATLAB language-server settings." {
      matlabPath = mkNullableStr "MATLAB installation path; omitted enables auto-detection.";
      matlabExtensionVersion = mkStr "1.3.9" "MathWorks VS Code extension version.";
    };
    pascal = mkLanguageOption "Pascal language-server settings." {
      paslsVersion = mkStr "v0.2.0" "pasls release version.";
      pp = mkStr "" "FPC compiler-driver path.";
      fpcdir = mkStr "" "FPC source directory.";
      lazarusdir = mkStr "" "Lazarus directory.";
      fpcTarget = mkStr "" "Target operating-system override.";
      fpcTargetCpu = mkStr "" "Target CPU override.";
    };
    perl = mkLanguageOption "Perl language-server settings." {
      fileFilter = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "File suffixes included in Perl Language Server indexing; null uses Serena's default (.pm, .pl, .t).";
      };
      ignoreDirs = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Directories the Perl Language Server skips; null uses Serena's default ignore list.";
      };
    };
    php = mkLanguageOption "Intelephense settings." {
      lsPath = lsPathOption;
      intelephenseVersion = mkStr "1.14.4" "Intelephense npm version.";
      npmRegistry = npmRegistryOption;
      ignoreVendor = mkBool true "Ignore Composer vendor directories.";
      maxFileSize = mkOption {
        type = types.nullOr numberType;
        default = null;
        description = "Value forwarded as intelephense.files.maxSize.";
      };
      maxMemory = mkOption {
        type = types.nullOr numberType;
        default = null;
        description = "Value forwarded as intelephense.maxMemory.";
      };
      fileFilter = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Additional file extensions (with leading dot) treated as PHP sources; null keeps the defaults (.php, .phtml).";
      };
    };
    phpPhpactor = mkLanguageOption "Phpactor settings." {
      lsPath = lsPathOption;
      phpactorVersion = mkStr "2025.12.21.1" "Phpactor PHAR version.";
      ignoreVendor = mkBool true "Ignore Composer vendor directories.";
    };
    phpPhpantom = mkLanguageOption "Phpantom settings." {
      ignoreVendor = mkBool true "Ignore Composer vendor directories.";
      phpantomVersion = mkStr "0.8.0" "Phpantom version.";
    };
    powershell = mkLanguageOption "PowerShell Editor Services settings." {
      psesVersion = mkStr "4.4.0" "PowerShell Editor Services version.";
      psscriptanalyzerVersion = mkStr "1.25.0" "PSScriptAnalyzer version.";
    };
    python = mkLanguageOption "Pyright settings." {
      lsPath = lsPathOption;
      pyrightVersion = mkStr "1.1.403" "Pyright PyPI version.";
    };
    pythonPyrefly = mkLanguageOption "Astral Pyrefly settings." {
      indexingMode = mkNullableStr "Pyrefly indexing mode forwarded as --indexing-mode; null uses Pyrefly's default.";
      pyreflyVersion = mkStr "1.1.1" "Pyrefly PyPI version.";
      workspaceIndexingLimit = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Workspace indexing limit forwarded as --workspace-indexing-limit; null uses Pyrefly's default.";
      };
    };
    pythonTy = mkLanguageOption "Astral ty settings." {
      lsPath = lsPathOption;
      tyVersion = mkStr "0.0.25" "ty PyPI version.";
    };
    ruby = mkLanguageOption "Ruby LSP settings." {
      rubyLspVersion = mkStr "0.26.8" "ruby-lsp gem version.";
    };
    rust = mkLanguageOption "rust-analyzer settings." { lsPath = lsPathOption; };
    scala = mkLanguageOption "Metals settings." {
      metalsVersion = mkStr "1.6.4" "Metals version.";
      clientName = mkStr "Serena" "Client identifier sent to Metals.";
      onStaleLock = mkOption {
        type = types.enum [
          "auto-clean"
          "warn"
          "fail"
        ];
        default = "auto-clean";
        description = "Behavior when a stale Metals database lock is found.";
      };
      logMultiInstanceNotice = mkBool true "Log when another Metals instance is detected.";
    };
    scss = mkLanguageOption "SCSS/Sass/CSS language-server settings." {
      lsPath = lsPathOption;
      someSassVersion = mkStr "2.3.8" "some-sass-language-server npm version.";
      npmRegistry = npmRegistryOption;
    };
    solidity = mkLanguageOption "Solidity language-server settings." {
      lsPath = lsPathOption;
      solidityLanguageServerVersion = mkStr "0.8.4" "Nomic Solidity language-server version.";
      forgeVersion = mkStr "1.5.1" "Managed Foundry forge npm package version.";
      npmRegistry = npmRegistryOption;
    };
    svelte = mkLanguageOption "Svelte language-server settings." {
      lsPath = lsPathOption;
      svelteLanguageServerVersion = mkStr "0.18.0" "Svelte language-server version.";
      typescriptVersion = mkStr "6.0.3" "TypeScript version shared by Svelte servers.";
      typescriptLanguageServerVersion = mkStr "5.1.3" "Companion TypeScript language-server version.";
      typescriptSveltePluginVersion = mkStr "0.3.52" "typescript-svelte-plugin version.";
      npmRegistry = npmRegistryOption;
      indexingTimeout = mkOption {
        type = types.nullOr numberType;
        default = null;
        description = "Indexing-progress timeout in seconds for Svelte's TypeScript server; null falls back to the TypeScript indexing_timeout (upstream default 120).";
      };
      initializationOptionsConfiguration = mkOption {
        type = jsonObjectType;
        default = { };
        description = "Svelte initialization configuration sections merged over Serena defaults.";
      };
    };
    systemverilog = mkLanguageOption "SystemVerilog language-server settings." {
      lsPath = lsPathOption;
      veribleVersion = mkStr "v0.0-4051-g9fdb4057" "Verible release tag.";
    };
    terraform = mkLanguageOption "Terraform language-server settings." {
      terraformLsVersion = mkStr "0.36.5" "terraform-ls version.";
    };
    toml = mkLanguageOption "Taplo settings." {
      lsPath = lsPathOption;
      taploVersion = mkStr "0.10.0" "Taplo version.";
    };
    typescript = mkLanguageOption "TypeScript language-server settings." {
      lsPath = lsPathOption;
      typescriptVersion = mkStr "5.9.3" "TypeScript version.";
      typescriptLanguageServerVersion = mkStr "5.1.3" "typescript-language-server version.";
      npmRegistry = npmRegistryOption;
      indexingTimeout = mkOption {
        type = types.nullOr numberType;
        default = null;
        description = "Indexing-progress timeout in seconds; null uses Serena's default (30).";
      };
      serverReadyTimeout = mkOption {
        type = types.nullOr numberType;
        default = null;
        description = "Language-server readiness timeout in seconds; null uses Serena's default (10).";
      };
    };
    typescriptVts = mkLanguageOption "vtsls settings." {
      vtslsVersion = mkStr "0.2.9" "@vtsls/language-server version.";
      npmRegistry = npmRegistryOption;
      initializationOptions = mkOption {
        type = types.nullOr jsonObjectType;
        default = null;
        description = "Raw vtsls initializationOptions; null lets Serena compute its defaults.";
      };
    };
    vue = mkLanguageOption "Vue language-server settings." {
      vueLanguageServerVersion = mkStr "3.1.5" "@vue/language-server version.";
      npmRegistry = npmRegistryOption;
    };
    yaml = mkLanguageOption "YAML language-server settings." {
      lsPath = lsPathOption;
      yamlLanguageServerVersion = mkStr "1.19.2" "yaml-language-server version.";
      npmRegistry = npmRegistryOption;
    };
  };

  mkLsSpecificSettingsOption =
    {
      description ? "Language-server-specific configuration, keyed by stable Serena language implementation.",
    }:
    mkOption {
      type = types.submodule { options = lsSpecificSettingsOptions; };
      default = { };
      inherit description;
    };

  toolInclusionOptions = {
    excludedTools = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Tool names to exclude.";
    };
    includedOptionalTools = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Optional tool names to enable.";
    };
    fixedTools = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Fixed base tool set; mutually exclusive with incremental inclusions and exclusions.";
    };
  };

  mkGlobalOptions =
    { }:
    toolInclusionOptions
    // {
      extraSettings = mkExtraSettingsOption ''
        Additional top-level Serena global settings. Typed options take
        precedence when rendered to the same upstream key.
      '';
      languageBackend = mkOption {
        type = types.enum [
          "LSP"
          "JetBrains"
        ];
        default = globalDefaults.languageBackend;
        description = "Default code-intelligence backend.";
      };
      lineEnding = mkOption {
        type = types.enum [
          "lf"
          "crlf"
          "native"
        ];
        default = globalDefaults.lineEnding;
        description = "Line-ending convention for source-file writes.";
      };
      guiLogWindow = mkBool globalDefaults.guiLogWindow "Open Serena's graphical log window.";
      webDashboard = mkBool globalDefaults.webDashboard "Enable the Serena dashboard.";
      webDashboardOpenOnLaunch = mkBool globalDefaults.webDashboardOpenOnLaunch "Open the dashboard when Serena starts.";
      webDashboardInterface = mkOption {
        type = types.nullOr (
          types.enum [
            "browser"
            "app"
            "tray_manager"
          ]
        );
        default = globalDefaults.webDashboardInterface;
        description = "Dashboard presentation interface; null selects Serena's platform default.";
      };
      webDashboardListenAddress = mkStr globalDefaults.webDashboardListenAddress "Dashboard bind address.";
      jetbrainsPluginServerAddress = mkStr globalDefaults.jetbrainsPluginServerAddress "JetBrains plugin server address.";
      jetbrainsLaunchCommand = mkNullableStr "Command used to launch a JetBrains IDE on demand when the JetBrains backend is active.";
      trustedProjectPathPatterns = mkOption {
        type = types.listOf types.str;
        default = globalDefaults.trustedProjectPathPatterns;
        description = "Glob patterns for trusted project roots; some project settings apply only to trusted projects.";
      };
      webDashboardTrustedHosts = mkOption {
        type = types.listOf types.str;
        default = globalDefaults.webDashboardTrustedHosts;
        description = "Hosts allowed to access the web dashboard; an empty list trusts all hosts.";
      };
      logLevel = mkOption {
        type = types.int;
        default = globalDefaults.logLevel;
        description = "Python logging threshold (10 debug, 20 info, 30 warning, 40 error).";
      };
      traceLspCommunication = mkBool globalDefaults.traceLspCommunication "Trace LSP communication.";
      lsSpecificSettings = mkLsSpecificSettingsOption { };
      ignoredPaths = mkOption {
        type = types.listOf types.str;
        default = globalDefaults.ignoredPaths;
        description = "Global gitignore-style path patterns.";
      };
      readOnlyMemoryPatterns = mkOption {
        type = types.listOf types.str;
        default = globalDefaults.readOnlyMemoryPatterns;
        description = "Regexes matching read-only memories.";
      };
      ignoredMemoryPatterns = mkOption {
        type = types.listOf types.str;
        default = globalDefaults.ignoredMemoryPatterns;
        description = "Regexes matching hidden and inaccessible memories.";
      };
      toolTimeout = mkOption {
        type = types.nullOr numberType;
        default = globalDefaults.toolTimeout;
        description = "Tool timeout in seconds; null waits indefinitely, otherwise use at least 10 seconds.";
      };
      baseModes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = globalDefaults.baseModes;
        description = "Modes that are always active.";
      };
      defaultModes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = globalDefaults.defaultModes;
        description = "Default modes, overridable per project or at startup.";
      };
      defaultMaxToolAnswerChars = mkOption {
        type = types.ints.positive;
        default = globalDefaults.defaultMaxToolAnswerChars;
        description = "Default maximum tool-answer length in characters.";
      };
      tokenCountEstimator = mkOption {
        type = types.enum [
          "CHAR_COUNT"
          "TIKTOKEN_GPT4O"
          "ANTHROPIC_CLAUDE_SONNET_4"
        ];
        default = globalDefaults.tokenCountEstimator;
        description = "Token estimator used for tool-usage statistics.";
      };
      symbolInfoBudget = mkOption {
        type = nonNegativeNumberType;
        default = globalDefaults.symbolInfoBudget;
        description = "Per-call symbol-info retrieval budget; zero disables early stopping.";
      };
      projectSerenaFolderLocation = mkStr globalDefaults.projectSerenaFolderLocation "Template for each project's Serena data directory.";
      projects = mkOption {
        type = types.listOf pathStringType;
        default = globalDefaults.projects;
        description = "Registered project roots. Serena may mutate this writable global file at runtime.";
      };
    };

  mkProjectOptions =
    {
      requireIdentity ? false,
    }:
    toolInclusionOptions
    // {
      extraSettings = mkExtraSettingsOption ''
        Additional top-level Serena project settings. Typed options take
        precedence when rendered to the same upstream key.
      '';
      projectName = mkOption (
        {
          type = types.str;
          description = "Stable project name used to reference the project from Serena.";
        }
        // optionalAttrs (!requireIdentity) { default = projectDefaults.projectName; }
      );
      languages = mkOption (
        {
          type =
            if requireIdentity then
              types.addCheck (types.listOf (types.enum languageValues)) (value: value != [ ])
            else
              types.listOf (types.enum languageValues);
          description = "Ordered language-server list; the first language is Serena's fallback.";
        }
        // optionalAttrs (!requireIdentity) { default = projectDefaults.languages; }
      );
      encoding = mkStr projectDefaults.encoding "Project source-file encoding.";
      lineEnding = mkOption {
        type = types.nullOr (
          types.enum [
            "lf"
            "crlf"
            "native"
          ]
        );
        default = projectDefaults.lineEnding;
        description = "Project line-ending override; null inherits global configuration.";
      };
      languageBackend = mkOption {
        type = types.nullOr (
          types.enum [
            "LSP"
            "JetBrains"
          ]
        );
        default = projectDefaults.languageBackend;
        description = "Project backend override; null inherits global configuration.";
      };
      ignoreAllFilesInGitignore = mkBool projectDefaults.ignoreAllFilesInGitignore "Honor project .gitignore files.";
      lsSpecificSettings = mkLsSpecificSettingsOption { };
      activationCommand = mkOption {
        type = types.nullOr types.str;
        default = projectDefaults.activationCommand;
        description = "Shell command run in the project root before the language backend initializes; trusted projects only.";
      };
      activationCommandTimeout = mkOption {
        type = numberType;
        default = projectDefaults.activationCommandTimeout;
        description = "Maximum seconds to wait for activationCommand before killing it; must be positive.";
      };
      lsAdditionalWorkspaceFolders = mkOption {
        type = types.listOf pathStringType;
        default = projectDefaults.lsAdditionalWorkspaceFolders;
        description = "Additional workspace folders for cross-package reference support; not indexed by Serena.";
      };
      lsWorkspaceFolders = mkOption {
        type = types.listOf types.str;
        default = projectDefaults.lsWorkspaceFolders;
        description = "Project-root-relative folders used to build Serena's symbol index.";
      };
      ignoredPaths = mkOption {
        type = types.listOf types.str;
        default = projectDefaults.ignoredPaths;
        description = "Additional project gitignore-style path patterns.";
      };
      readOnly = mkBool projectDefaults.readOnly "Disable editing tools for this project.";
      defaultModes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = projectDefaults.defaultModes;
        description = "Project default-mode override; [] suppresses global defaults and null inherits them.";
      };
      addedModes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = projectDefaults.addedModes;
        description = "Modes added whenever this project is active.";
      };
      initialPrompt = mkStr projectDefaults.initialPrompt "Prompt always supplied when the project is activated.";
      symbolInfoBudget = mkOption {
        type = types.nullOr nonNegativeNumberType;
        default = projectDefaults.symbolInfoBudget;
        description = "Project symbol-info retrieval budget; null inherits global configuration.";
      };
      readOnlyMemoryPatterns = mkOption {
        type = types.listOf types.str;
        default = projectDefaults.readOnlyMemoryPatterns;
        description = "Additional regexes matching read-only memories.";
      };
      ignoredMemoryPatterns = mkOption {
        type = types.listOf types.str;
        default = projectDefaults.ignoredMemoryPatterns;
        description = "Additional regexes matching hidden and inaccessible memories.";
      };
    };

  mkContextOptions =
    { }:
    toolInclusionOptions
    // {
      extraSettings = mkExtraSettingsOption ''
        Additional context settings. Typed options take precedence when
        rendered to the same upstream key.
      '';
      prompt = mkOption {
        type = types.str;
        description = "Required Jinja prompt contributed by this context.";
      };
      description = mkStr contextDefaults.description "Human-readable context description.";
      toolDescriptionOverrides = mkOption {
        type = types.attrsOf types.str;
        default = contextDefaults.toolDescriptionOverrides;
        description = "Tool-name to replacement-description mapping.";
      };
      singleProject = mkBool contextDefaults.singleProject "Limit Serena to the project supplied at startup.";
      structuredToolOutput = mkOption {
        type = types.nullOr types.bool;
        default = contextDefaults.structuredToolOutput;
        description = "Whether MCP tools return structured output; null auto-detects client support.";
      };
    };

  mkModeOptions =
    { }:
    toolInclusionOptions
    // {
      extraSettings = mkExtraSettingsOption ''
        Additional mode settings. Typed options take precedence when rendered
        to the same upstream key.
      '';
      prompt = mkOption {
        type = types.str;
        description = "Required Jinja prompt contributed by this mode.";
      };
      description = mkStr modeDefaults.description "Human-readable mode description.";
    };

  promptValueType = types.either types.str (types.listOf types.str);

  promptTemplateOptions = {
    connectionPrompt = mkOption {
      type = types.nullOr promptValueType;
      default = null;
      description = "Override for connection_prompt.";
    };
    systemPrompt = mkOption {
      type = types.nullOr promptValueType;
      default = null;
      description = "Override for system_prompt.";
    };
    ccSystemPromptOverride = mkOption {
      type = types.nullOr promptValueType;
      default = null;
      description = "Override for cc_system_prompt_override.";
    };
    infoJetBrainsDebugRepl = mkOption {
      type = types.nullOr promptValueType;
      default = null;
      description = "Override for info_jet_brains_debug_repl.";
    };
    onboardingPrompt = mkOption {
      type = types.nullOr promptValueType;
      default = null;
      description = "Override for onboarding_prompt.";
    };
    extraPrompts = mkOption {
      type = types.attrsOf promptValueType;
      default = { };
      description = "Additional prompt names using their exact upstream spelling.";
    };
  };

  mkPromptTemplatesOption =
    {
      description ? "Prompt-template YAML files keyed by filename or filename stem.",
    }:
    mkOption {
      type = types.attrsOf (types.submodule { options = promptTemplateOptions; });
      default = { };
      inherit description;
    };

  fixedToolAssertion = label: value: {
    assertion =
      (value.fixedTools or [ ]) == [ ]
      || ((value.excludedTools or [ ]) == [ ] && (value.includedOptionalTools or [ ]) == [ ]);
    message = "${label}: fixedTools cannot be combined with excludedTools or includedOptionalTools.";
  };

  validProjectFolderTemplate =
    value:
    let
      withoutKnown =
        builtins.replaceStrings
          [
            "$projectDir"
            "$projectFolderName"
          ]
          [
            ""
            ""
          ]
          value;
    in
    builtins.match ".*\\$[A-Za-z_][A-Za-z0-9_]*.*" withoutKnown == null;

  assertionsFor =
    {
      scope,
      config,
      languages ? config.languages or [ ],
      inheritedLsSpecificSettings ? { },
      label ? "Serena ${scope} configuration",
    }:
    let
      effectiveLs = inheritedLsSpecificSettings // (config.lsSpecificSettings or { });
      java = effectiveLs.java or null;
      clojure = effectiveLs.clojure or null;
      groovy = effectiveLs.groovy or null;
      hasJdtls = java != null && java.jdtlsPath != null;
      hasLombok = java != null && java.lombokPath != null;
    in
    [ (fixedToolAssertion label config) ]
    ++ lib.optionals (scope == "global") [
      {
        assertion = config.toolTimeout == null || config.toolTimeout >= 10;
        message = "${label}: toolTimeout must be null or at least 10 seconds.";
      }
      {
        assertion = validProjectFolderTemplate config.projectSerenaFolderLocation;
        message = "${label}: projectSerenaFolderLocation supports only $projectDir and $projectFolderName placeholders.";
      }
    ]
    ++ lib.optionals (java != null) [
      {
        assertion = hasJdtls == hasLombok;
        message = "${label}: Java jdtlsPath and lombokPath must be set together.";
      }
    ]
    ++ lib.optionals (scope == "project") [
      {
        assertion =
          !(builtins.elem "angular" languages)
          || (!(builtins.elem "typescript" languages) && !(builtins.elem "html" languages));
        message = "${label}: angular subsumes typescript and html; do not enable those language servers together.";
      }
      {
        assertion = !(builtins.elem "groovy" languages) || (groovy != null && groovy.lsJarPath != null);
        message = "${label}: Groovy projects require lsSpecificSettings.groovy.lsJarPath.";
      }
    ];

  warningsFor =
    {
      scope,
      config,
      languages ? config.languages or [ ],
      inheritedLsSpecificSettings ? { },
    }:
    let
      effectiveLs = inheritedLsSpecificSettings // (config.lsSpecificSettings or { });
      clojure = effectiveLs.clojure or null;
      svelte = effectiveLs.svelte or null;
    in
    lib.optionals (clojure != null && clojure.sourcePaths != null && clojure.configEdnPath != null) [
      "Serena ${scope} configuration: Clojure sourcePaths takes precedence over configEdnPath."
    ]
    ++ lib.optionals (svelte != null && svelte.lsPath != null) [
      "Serena ${scope} configuration: v1.6.1 svelte.lsPath bypasses installation but still expects managed companion TypeScript files."
    ]
    ++
      lib.optionals
        (scope == "project" && builtins.elem "svelte" languages && builtins.elem "typescript" languages)
        [
          "Serena project configuration: svelte and typescript create overlapping language servers; keep both only intentionally."
        ];
in
rec {
  inherit
    assertionsFor
    builtinContexts
    builtinModes
    contextDefaults
    contextFieldMappings
    globalDefaults
    globalFieldMappings
    javaRuntimeFieldMappings
    javaRuntimeType
    jsonObjectType
    jsonValueType
    languageValues
    lsFieldMappings
    lsLanguageMappings
    mkContextOptions
    mkGlobalOptions
    mkExtraSettingsOption
    mkLsSpecificSettingsOption
    mkModeOptions
    mkProjectOptions
    mkPromptTemplatesOption
    modeDefaults
    modeFieldMappings
    pathStringType
    projectDefaults
    projectFieldMappings
    promptFieldMappings
    promptTemplateOptions
    promptValueType
    runtimeDependencyFieldMappings
    runtimeDependencyType
    warningsFor
    ;

  globalSettingsType = types.submodule { options = mkGlobalOptions { }; };
  projectSettingsType = types.submodule { options = mkProjectOptions { requireIdentity = true; }; };
  contextSettingsType = types.submodule { options = mkContextOptions { }; };
  modeSettingsType = types.submodule { options = mkModeOptions { }; };

  manifest = {
    schemaVersion = 2;
    upstreamVersion = "1.6.1";
    inherit languageValues builtinContexts builtinModes;
    defaults = {
      global = globalDefaults;
      project = projectDefaults;
      context = contextDefaults;
      mode = modeDefaults;
    };
    mappings = {
      global = globalFieldMappings;
      project = projectFieldMappings;
      context = contextFieldMappings;
      mode = modeFieldMappings;
      lsLanguages = lsLanguageMappings;
      lsFields = lsFieldMappings;
      runtimeDependency = runtimeDependencyFieldMappings;
      javaRuntime = javaRuntimeFieldMappings;
      prompt = promptFieldMappings;
    };
    templateFields = {
      global = builtins.attrValues globalFieldMappings;
      project = builtins.attrValues projectFieldMappings;
      context = builtins.filter (name: name != "name" && name != "fixed_tools") (
        builtins.attrValues contextFieldMappings
      );
      mode = builtins.filter (name: name != "name" && name != "fixed_tools") (
        builtins.attrValues modeFieldMappings
      );
    };
    sourceExtensions = {
      context = [ "fixed_tools" ];
      mode = [ "fixed_tools" ];
      lsSpecificSettings = [
        "ada"
        "cue"
        "fortran"
        "json"
        "luau"
        "python_ty"
        "elm.elm_compiler_version"
        "powershell.psscriptanalyzer_version"
        "python.pyright_version"
        "solidity.forge_version"
      ];
    };
    promptTemplates = {
      containerKey = "prompts";
      valueTypes = [
        "string"
        "list-of-strings"
      ];
      arbitraryPromptOption = "extraPrompts";
      multilingualLangOption = null;
    };
    escapeHatches = {
      option = "extraSettings";
      emittedKey = null;
      precedence = "typed-options-win";
      scopes = [
        "global"
        "project"
        "context"
        "mode"
        "ls-specific-settings"
      ];
    };
  };
}
