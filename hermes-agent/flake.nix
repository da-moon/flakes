{
  description = "Hermes Agent - self-improving AI agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "hermes-agent";
        version = "unstable-2026-04-08";
        revision = "ff6a86cb529a372198b4b80d5e022e32a4a3f2cc";

        sourceHashBySystem = {
          "aarch64-linux" = "sha256-m1DICRvc4jc1Rar0zKrVA6TYXjef8QFRXjRc5/AU0rc=";
          "x86_64-linux" = "sha256-m1DICRvc4jc1Rar0zKrVA6TYXjef8QFRXjRc5/AU0rc=";
        };

        sourceRoot = pkgs.fetchFromGitHub {
          owner = "NousResearch";
          repo = "hermes-agent";
          rev = revision;
          hash = sourceHashBySystem.${system} or (throw "Missing source hash for system ${system}");
        };

        patchedSource = pkgs.runCommand "${pname}-source-${version}" { } ''
          cp -r ${sourceRoot} "$out"
          chmod -R u+w "$out"

          PATCHED_ROOT="$out" ${pkgs.python3}/bin/python - <<'PY'
from os import environ
from pathlib import Path
import re

root = Path(environ["PATCHED_ROOT"])

def replace_first(text: str, pattern: str, replacement: str, path_str: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"Failed to locate patch target in {path_str}: {pattern}")
    return updated

rl_training_path = root / "tools" / "rl_training_tool.py"
rl_training_text = rl_training_path.read_text()
rl_training_original = rl_training_text

rl_training_header = 'HERMES_HOME = Path(os.getenv("HERMES_HOME", Path.home() / ".hermes"))'
if rl_training_header not in rl_training_text:
    rl_training_text = replace_first(
        rl_training_text,
        r'# Path to tinker-atropos submodule \(relative to hermes-agent root\)\nHERMES_ROOT = Path\(__file__\)\.parent\.parent',
        '# Path to tinker-atropos workspace (defaulting to a user-writable Hermes home path)\nHERMES_HOME = Path(os.getenv("HERMES_HOME", Path.home() / ".hermes"))\nHERMES_ROOT = Path(__file__).parent.parent',
        "tools/rl_training_tool.py",
    )

rl_training_root = 'TINKER_ATROPOS_ROOT = Path(os.getenv("TINKER_ATROPOS_ROOT", str(HERMES_HOME / "tinker-atropos")))'
if rl_training_root not in rl_training_text:
    rl_training_text = replace_first(
        rl_training_text,
        r'TINKER_ATROPOS_ROOT = HERMES_ROOT / "tinker-atropos"',
        rl_training_root,
        "tools/rl_training_tool.py",
    )

rl_training_logs = 'LOGS_DIR = Path(os.getenv("TINKER_LOGS_DIR", str(HERMES_HOME / "logs" / "rl_training")))'
if rl_training_logs not in rl_training_text:
    rl_training_text = replace_first(
        rl_training_text,
        r'LOGS_DIR = (?:TINKER_ATROPOS_ROOT / "logs"|Path\(os.getenv\("HERMES_HOME", Path\.home\(\) / "\.hermes"\)\) / "logs" / "rl_training"|get_hermes_home\(\) / "logs" / "rl_training")',
        rl_training_logs,
        "tools/rl_training_tool.py",
    )

if 'CONFIGS_DIR.mkdir(parents=True, exist_ok=True)' not in rl_training_text:
    rl_training_text = replace_first(
        rl_training_text,
        r'CONFIGS_DIR\.mkdir\(exist_ok=True\)',
        'CONFIGS_DIR.mkdir(parents=True, exist_ok=True)',
        "tools/rl_training_tool.py",
    )

if 'LOGS_DIR.mkdir(parents=True, exist_ok=True)' not in rl_training_text:
    rl_training_text = replace_first(
        rl_training_text,
        r'LOGS_DIR\.mkdir\(exist_ok=True\)',
        'LOGS_DIR.mkdir(parents=True, exist_ok=True)',
        "tools/rl_training_tool.py",
    )

if rl_training_text != rl_training_original:
    rl_training_path.write_text(rl_training_text)

doctor_path = root / "hermes_cli" / "doctor.py"
doctor_new = """    # Node.js + agent-browser (for browser automation tools)
    agent_browser_on_path = shutil.which("agent-browser")
    local_agent_browser = PROJECT_ROOT / "node_modules" / "agent-browser"
    hermes_nix_managed = os.getenv("HERMES_NIX_MANAGED") == "1"

    if agent_browser_on_path:
        detail = "(browser automation via PATH)"
        if hermes_nix_managed:
            detail = "(browser automation via Nix PATH)"
        check_ok("agent-browser", detail)
    elif local_agent_browser.exists():
        if shutil.which("node"):
            check_ok("Node.js")
        else:
            check_warn("Node.js not found", "(local repo agent-browser still needs Node.js)")
        check_ok("agent-browser (Node.js)", "(browser automation)")
    elif shutil.which("node"):
        check_ok("Node.js")
        check_warn("agent-browser not installed", "(run: npm install)")
    else:
        check_warn("agent-browser not found", "(optional, install agent-browser or enable the Nix browser integration)")
"""
doctor_text = doctor_path.read_text()
doctor_pattern = re.compile(
    r'    # Node\.js \+ agent-browser \(for browser automation tools\)\n.*?(?=    # npm audit for all Node\.js packages)',
    re.S,
)
doctor_match = doctor_pattern.search(doctor_text)
if not doctor_match:
    raise SystemExit("Failed to locate browser diagnostics block in hermes_cli/doctor.py")
doctor_path.write_text(doctor_text[:doctor_match.start()] + doctor_new + doctor_text[doctor_match.end():])

gateway_run_path = root / "gateway" / "run.py"
model_new = """    async def _handle_model_command(self, event: MessageEvent) -> Optional[str]:
        \"\"\"Handle /model command — switch model for this session.

        Supports:
          /model                              — interactive picker (Telegram/Discord) or text list
          /model <name>                       — switch for this session only
          /model <name> --global              — switch and persist to config.yaml
          /model <name> --provider <provider> — switch provider + model
          /model --provider <provider>        — switch to provider, auto-detect model
        \"\"\"
        import yaml
        from hermes_cli.model_switch import (
            switch_model as _switch_model, parse_model_flags,
            list_authenticated_providers,
        )
        from hermes_cli.providers import get_label

        raw_args = event.get_command_args().strip()

        # Parse --provider and --global flags
        model_input, explicit_provider, persist_global = parse_model_flags(raw_args)

        # Read current model/provider from config
        current_model = ""
        current_provider = "openrouter"
        current_base_url = ""
        current_api_key = ""
        user_provs = None
        config_path = _hermes_home / "config.yaml"
        try:
            if config_path.exists():
                with open(config_path, encoding="utf-8") as f:
                    cfg = yaml.safe_load(f) or {}
                model_cfg = cfg.get("model", {})
                if isinstance(model_cfg, dict):
                    current_model = model_cfg.get("default", "")
                    current_provider = model_cfg.get("provider", current_provider)
                    current_base_url = model_cfg.get("base_url", "")
                user_provs = cfg.get("providers")
        except Exception:
            pass

        # Check for session override
        source = event.source
        session_key = self._session_key_for_source(source)
        override = getattr(self, "_session_model_overrides", {}).get(session_key, {})
        if override:
            current_model = override.get("model", current_model)
            current_provider = override.get("provider", current_provider)
            current_base_url = override.get("base_url", current_base_url)
            current_api_key = override.get("api_key", current_api_key)

        # No args: show interactive picker (Telegram/Discord) or text list
        if not model_input and not explicit_provider:
            # Try interactive picker if the platform supports it
            adapter = self.adapters.get(source.platform)
            has_picker = (
                adapter is not None
                and getattr(type(adapter), "send_model_picker", None) is not None
            )

            if has_picker:
                try:
                    providers = list_authenticated_providers(
                        current_provider=current_provider,
                        user_providers=user_provs,
                        max_models=50,
                    )
                except Exception:
                    providers = []

                if providers:
                    # Build a callback closure for when the user picks a model.
                    # Captures self + locals needed for the switch logic.
                    _self = self
                    _session_key = session_key
                    _cur_model = current_model
                    _cur_provider = current_provider
                    _cur_base_url = current_base_url
                    _cur_api_key = current_api_key

                    async def _on_model_selected(
                        _chat_id: str, model_id: str, provider_slug: str
                    ) -> str:
                        \"\"\"Perform the model switch and return confirmation text.\"\"\"
                        result = _switch_model(
                            raw_input=model_id,
                            current_provider=_cur_provider,
                            current_model=_cur_model,
                            current_base_url=_cur_base_url,
                            current_api_key=_cur_api_key,
                            is_global=False,
                            explicit_provider=provider_slug,
                        )
                        if not result.success:
                            return f"Error: {result.error_message}"

                        # Update cached agent in-place
                        cached_entry = None
                        _cache_lock = getattr(_self, "_agent_cache_lock", None)
                        _cache = getattr(_self, "_agent_cache", None)
                        if _cache_lock and _cache is not None:
                            with _cache_lock:
                                cached_entry = _cache.get(_session_key)
                        if cached_entry and cached_entry[0] is not None:
                            try:
                                cached_entry[0].switch_model(
                                    new_model=result.new_model,
                                    new_provider=result.target_provider,
                                    api_key=result.api_key,
                                    base_url=result.base_url,
                                    api_mode=result.api_mode,
                                )
                            except Exception as exc:
                                logger.warning("Picker model switch failed for cached agent: %s", exc)

                        # Store model note + session override
                        if not hasattr(_self, "_pending_model_notes"):
                            _self._pending_model_notes = {}
                        _self._pending_model_notes[_session_key] = (
                            f"[Note: model was just switched from {_cur_model} to {result.new_model} "
                            f"via {result.provider_label or result.target_provider}. "
                            f"Adjust your self-identification accordingly.]"
                        )
                        if not hasattr(_self, "_session_model_overrides"):
                            _self._session_model_overrides = {}
                        _self._session_model_overrides[_session_key] = {
                            "model": result.new_model,
                            "provider": result.target_provider,
                            "api_key": result.api_key,
                            "base_url": result.base_url,
                            "api_mode": result.api_mode,
                        }

                        # Build confirmation text
                        plabel = result.provider_label or result.target_provider
                        lines = [f"Model switched to `{result.new_model}`"]
                        lines.append(f"Provider: {plabel}")
                        mi = result.model_info
                        if mi:
                            if mi.context_window:
                                lines.append(f"Context: {mi.context_window:,} tokens")
                            if mi.max_output:
                                lines.append(f"Max output: {mi.max_output:,} tokens")
                            if mi.has_cost_data():
                                lines.append(f"Cost: {mi.format_cost()}")
                            lines.append(f"Capabilities: {mi.format_capabilities()}")
                        lines.append("_(session only — use `/model <name> --global` to persist)_")
                        return "\\n".join(lines)

                    metadata = {"thread_id": source.thread_id} if source.thread_id else None
                    result = await adapter.send_model_picker(
                        chat_id=source.chat_id,
                        providers=providers,
                        current_model=current_model,
                        current_provider=current_provider,
                        session_key=session_key,
                        on_model_selected=_on_model_selected,
                        metadata=metadata,
                    )
                    if result.success:
                        return None  # Picker sent — adapter handles the response

            # Fallback: text list (for platforms without picker or if picker failed)
            provider_label = get_label(current_provider)
            lines = [f"Current: `{current_model or 'unknown'}` on {provider_label}", ""]

            try:
                providers = list_authenticated_providers(
                    current_provider=current_provider,
                    user_providers=user_provs,
                    max_models=5,
                )
                for p in providers:
                    tag = " (current)" if p["is_current"] else ""
                    lines.append(f"**{p['name']}** `--provider {p['slug']}`{tag}:")
                    if p["models"]:
                        model_strs = ", ".join(f"`{m}`" for m in p["models"])
                        extra = f" (+{p['total_models'] - len(p['models'])} more)" if p["total_models"] > len(p["models"]) else ""
                        lines.append(f"  {model_strs}{extra}")
                    elif p.get("api_url"):
                        lines.append(f"  `{p['api_url']}`")
                    lines.append("")
            except Exception:
                pass

            lines.append("`/model <name>` — switch model")
            lines.append("`/model <name> --provider <slug>` — switch provider")
            lines.append("`/model <name> --global` — persist")
            return "\\n".join(lines)

        # Perform the switch
        result = _switch_model(
            raw_input=model_input,
            current_provider=current_provider,
            current_model=current_model,
            current_base_url=current_base_url,
            current_api_key=current_api_key,
            is_global=persist_global,
            explicit_provider=explicit_provider,
        )

        if not result.success:
            return f"Error: {result.error_message}"

        # If there's a cached agent, update it in-place
        cached_entry = None
        _cache_lock = getattr(self, "_agent_cache_lock", None)
        _cache = getattr(self, "_agent_cache", None)
        if _cache_lock and _cache is not None:
            with _cache_lock:
                cached_entry = _cache.get(session_key)

        if cached_entry and cached_entry[0] is not None:
            try:
                cached_entry[0].switch_model(
                    new_model=result.new_model,
                    new_provider=result.target_provider,
                    api_key=result.api_key,
                    base_url=result.base_url,
                    api_mode=result.api_mode,
                )
            except Exception as exc:
                logger.warning("In-place model switch failed for cached agent: %s", exc)

        # Store a note to prepend to the next user message so the model
        # knows about the switch (avoids system messages mid-history).
        if not hasattr(self, "_pending_model_notes"):
            self._pending_model_notes = {}
        self._pending_model_notes[session_key] = (
            f"[Note: model was just switched from {current_model} to {result.new_model} "
            f"via {result.provider_label or result.target_provider}. "
            f"Adjust your self-identification accordingly.]"
        )

        # Store session override so next agent creation uses the new model
        if not hasattr(self, "_session_model_overrides"):
            self._session_model_overrides = {}
        self._session_model_overrides[session_key] = {
            "model": result.new_model,
            "provider": result.target_provider,
            "api_key": result.api_key,
            "base_url": result.base_url,
            "api_mode": result.api_mode,
        }

        # Build confirmation message with full metadata
        provider_label = result.provider_label or result.target_provider
        lines = [f"Model switched to `{result.new_model}`"]
        lines.append(f"Provider: {provider_label}")

        # Rich metadata from models.dev
        mi = result.model_info
        if mi:
            if mi.context_window:
                lines.append(f"Context: {mi.context_window:,} tokens")
            if mi.max_output:
                lines.append(f"Max output: {mi.max_output:,} tokens")
            if mi.has_cost_data():
                lines.append(f"Cost: {mi.format_cost()}")
            lines.append(f"Capabilities: {mi.format_capabilities()}")
        else:
            try:
                from agent.model_metadata import get_model_context_length
                ctx = get_model_context_length(
                    result.new_model,
                    base_url=result.base_url or current_base_url,
                    api_key=result.api_key or current_api_key,
                    provider=result.target_provider,
                )
                lines.append(f"Context: {ctx:,} tokens")
            except Exception:
                pass

        # Cache notice
        cache_enabled = (
            ("openrouter" in (result.base_url or "").lower() and "claude" in result.new_model.lower())
            or result.api_mode == "anthropic_messages"
        )
        if cache_enabled:
            lines.append("Prompt caching: enabled")

        if result.warning_message:
            lines.append(f"Warning: {result.warning_message}")

        if persist_global:
            if os.getenv("HERMES_NIX_MANAGED") == "1":
                lines.append(
                    "Saved for this Hermes process only under Nix; set programs.hermes-agent.settings.model.default and re-run Home Manager to persist."
                )
            else:
                try:
                    if config_path.exists():
                        with open(config_path, encoding="utf-8") as f:
                            cfg = yaml.safe_load(f) or {}
                    else:
                        cfg = {}
                    model_cfg = cfg.setdefault("model", {})
                    model_cfg["default"] = result.new_model
                    model_cfg["provider"] = result.target_provider
                    if result.base_url:
                        model_cfg["base_url"] = result.base_url
                    from hermes_cli.config import save_config
                    save_config(cfg)
                except Exception as e:
                    logger.warning("Failed to persist model switch: %s", e)
                else:
                    lines.append("Saved to config.yaml (`--global`)")
        else:
            lines.append("_(session only -- add `--global` to persist)_")

        return "\\n".join(lines)
"""
personality_new = """    async def _handle_personality_command(self, event: MessageEvent) -> str:
        \"\"\"Handle /personality command - list or set a personality.\"\"\"
        import yaml

        args = event.get_command_args().strip().lower()
        config_path = _hermes_home / 'config.yaml'
        nix_managed = os.getenv("HERMES_NIX_MANAGED") == "1"

        try:
            if config_path.exists():
                with open(config_path, 'r', encoding="utf-8") as f:
                    config = yaml.safe_load(f) or {}
                personalities = config.get("agent", {}).get("personalities", {})
            else:
                config = {}
                personalities = {}
        except Exception:
            config = {}
            personalities = {}

        if not personalities:
            return "No personalities configured in `~/.hermes/config.yaml`"

        if not args:
            lines = ["🎭 **Available Personalities**\\n"]
            lines.append("• `none` — (no personality overlay)")
            for name, prompt in personalities.items():
                if isinstance(prompt, dict):
                    preview = prompt.get("description") or prompt.get("system_prompt", "")[:50]
                else:
                    preview = prompt[:50] + "..." if len(prompt) > 50 else prompt
                lines.append(f"• `{name}` — {preview}")
            lines.append("\\nUsage: `/personality <name>`")
            return "\\n".join(lines)

        def _resolve_prompt(value):
            if isinstance(value, dict):
                parts = [value.get("system_prompt", "")]
                if value.get("tone"):
                    parts.append(f'Tone: {value["tone"]}')
                if value.get("style"):
                    parts.append(f'Style: {value["style"]}')
                return "\\n".join(p for p in parts if p)
            return str(value)

        if args in ("none", "default", "neutral"):
            if nix_managed:
                self._ephemeral_system_prompt = ""
                return (
                    "🎭 Personality cleared — using base agent behavior for this Hermes process only.\\n"
                    "To persist it under Nix, set settings.agent.system_prompt or manage a SOUL.md file declaratively."
                )

            try:
                if "agent" not in config or not isinstance(config.get("agent"), dict):
                    config["agent"] = {}
                config["agent"]["system_prompt"] = ""
                atomic_yaml_write(config_path, config)
            except Exception as e:
                return f"⚠️ Failed to save personality change: {e}"
            self._ephemeral_system_prompt = ""
            return "🎭 Personality cleared — using base agent behavior.\\n_(takes effect on next message)_"
        elif args in personalities:
            new_prompt = _resolve_prompt(personalities[args])

            if nix_managed:
                self._ephemeral_system_prompt = new_prompt
                return (
                    f"🎭 Personality set to **{args}** for this Hermes process only.\\n"
                    "To persist it under Nix, set settings.agent.system_prompt or manage a SOUL.md file declaratively."
                )

            # Write to config.yaml, same pattern as CLI save_config_value.
            try:
                if "agent" not in config or not isinstance(config.get("agent"), dict):
                    config["agent"] = {}
                config["agent"]["system_prompt"] = new_prompt
                atomic_yaml_write(config_path, config)
            except Exception as e:
                return f"⚠️ Failed to save personality change: {e}"

            self._ephemeral_system_prompt = new_prompt
            return f"🎭 Personality set to **{args}**\\n_(takes effect on next message)_"

        available = "`none`, " + ", ".join(f"`{n}`" for n in personalities)
        return f"Unknown personality: `{args}`\\n\\nAvailable: {available}"
"""
sethome_new = """    async def _handle_set_home_command(self, event: MessageEvent) -> str:
        \"\"\"Handle /sethome command -- set the current chat as the platform's home channel.\"\"\"
        source = event.source
        platform_name = source.platform.value if source.platform else "unknown"
        chat_id = source.chat_id
        chat_name = source.chat_name or chat_id

        env_key = f"{platform_name.upper()}_HOME_CHANNEL"

        if os.getenv("HERMES_NIX_MANAGED") == "1":
            from gateway.config import HomeChannel, PlatformConfig

            if source.platform and source.platform not in self.config.platforms:
                self.config.platforms[source.platform] = PlatformConfig(enabled=True)
            if source.platform:
                self.config.platforms[source.platform].home_channel = HomeChannel(
                    platform=source.platform,
                    chat_id=str(chat_id),
                    name=chat_name,
                )
            os.environ[env_key] = str(chat_id)

            return (
                f"Home channel set to **{chat_name}** (ID: {chat_id}) for this Hermes process only.\\n"
                f"To persist it under Nix, set {env_key}={chat_id} through your Hermes env/envFile configuration and re-run Home Manager."
            )

        # Save to config.yaml
        try:
            import yaml
            config_path = _hermes_home / 'config.yaml'
            user_config = {}
            if config_path.exists():
                with open(config_path) as f:
                    user_config = yaml.safe_load(f) or {}
            user_config[env_key] = chat_id
            with open(config_path, 'w') as f:
                yaml.dump(user_config, f, default_flow_style=False)
            # Also set in the current environment so it takes effect immediately
            os.environ[env_key] = str(chat_id)
        except Exception as e:
            return f"Failed to save home channel: {e}"

        return (
            f"✅ Home channel set to **{chat_name}** (ID: {chat_id}).\\n"
            f"Cron jobs and cross-platform messages will be delivered here."
        )
"""
update_new = """    async def _handle_update_command(self, event: MessageEvent) -> str:
        \"\"\"Handle /update command — update Hermes Agent to the latest version.\"\"\"
        if os.getenv("HERMES_NIX_MANAGED") == "1":
            return "✗ `/update` is disabled in the Nix package. Update the pinned flake input and re-run Home Manager."

        import json
        import shutil
        import subprocess
        from datetime import datetime

        project_root = Path(__file__).parent.parent.resolve()
        git_dir = project_root / '.git'

        if not git_dir.exists():
            return "✗ Not a git repository — cannot update."

        hermes_bin = shutil.which("hermes")
        if not hermes_bin:
            return "✗ `hermes` command not found on PATH."

        pending_path = _hermes_home / ".update_pending.json"
        output_path = _hermes_home / ".update_output.txt"
        pending = {
            "platform": event.source.platform.value,
            "chat_id": event.source.chat_id,
            "user_id": event.source.user_id,
            "timestamp": datetime.now().isoformat(),
        }
        pending_path.write_text(json.dumps(pending))

        update_cmd = f"{hermes_bin} update > {output_path} 2>&1"
        try:
            systemd_run = shutil.which("systemd-run")
            if systemd_run:
                subprocess.Popen(
                    [systemd_run, "--user", "--scope",
                     "--unit=hermes-update", "--",
                     "bash", "-c", update_cmd],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            else:
                subprocess.Popen(
                    ["bash", "-c", f"nohup {update_cmd} &"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
        except Exception as e:
            pending_path.unlink(missing_ok=True)
            return f"✗ Failed to start update: {e}"

        return "⚕ Starting Hermes update… I'll notify you when it's done."
"""
gateway_run_text = gateway_run_path.read_text()
model_pattern = re.compile(
    r'    async def _handle_model_command\(self, event: MessageEvent\) -> Optional\[str\]:\n.*?(?=    async def _handle_provider_command|    async def _handle_personality_command)',
    re.S,
)
model_match = model_pattern.search(gateway_run_text)
if not model_match:
    raise SystemExit("Failed to locate _handle_model_command in gateway/run.py")
gateway_run_text = gateway_run_text[:model_match.start()] + model_new + gateway_run_text[model_match.end():]

personality_pattern = re.compile(
    r'    async def _handle_personality_command\(self, event: MessageEvent\) -> str:\n.*?(?=    async def _handle_retry_command)',
    re.S,
)
personality_match = personality_pattern.search(gateway_run_text)
if not personality_match:
    raise SystemExit("Failed to locate _handle_personality_command in gateway/run.py")
gateway_run_text = gateway_run_text[:personality_match.start()] + personality_new + gateway_run_text[personality_match.end():]

sethome_pattern = re.compile(
    r'    async def _handle_set_home_command\(self, event: MessageEvent\) -> str:\n.*?(?=    async def _handle_compress_command)',
    re.S,
)
sethome_match = sethome_pattern.search(gateway_run_text)
if not sethome_match:
    raise SystemExit("Failed to locate _handle_set_home_command in gateway/run.py")
gateway_run_text = gateway_run_text[:sethome_match.start()] + sethome_new + gateway_run_text[sethome_match.end():]

update_pattern = re.compile(
    r'    async def _handle_update_command\(self, event: MessageEvent\) -> str:\n.*?(?=    async def _send_update_notification)',
    re.S,
)
update_match = update_pattern.search(gateway_run_text)
if not update_match:
    raise SystemExit("Failed to locate _handle_update_command in gateway/run.py")
gateway_run_path.write_text(gateway_run_text[:update_match.start()] + update_new + gateway_run_text[update_match.end():])

cli_path = root / "cli.py"
cli_text = cli_path.read_text()
save_config_guard = """def save_config_value(key_path: str, value: any) -> bool:
    \"\"\"
    Save a value to the active config file at the specified key path.
    
    Respects the same lookup order as load_cli_config():
    1. ~/.hermes/config.yaml (user config - preferred, used if it exists)
    2. ./cli-config.yaml (project config - fallback)
    
    Args:
        key_path: Dot-separated path like "agent.system_prompt"
        value: Value to save
    
    Returns:
        True if successful, False otherwise
    \"\"\"
    if os.getenv("HERMES_NIX_MANAGED") == "1" and key_path in {"agent.system_prompt", "model.default"}:
        return False

    # Use the same precedence as load_cli_config: user config first, then project config
    user_config_path = _hermes_home / 'config.yaml'
    project_config_path = Path(__file__).parent / 'cli-config.yaml'
    config_path = user_config_path if user_config_path.exists() else project_config_path
    
    try:
        # Ensure parent directory exists (for ~/.hermes/config.yaml on first use)
        config_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Load existing config
        if config_path.exists():
            with open(config_path, 'r') as f:
                config = yaml.safe_load(f) or {}
        else:
            config = {}
        
        # Navigate to the key and set value
        keys = key_path.split('.')
        current = config
        for key in keys[:-1]:
            if key not in current or not isinstance(current[key], dict):
                current[key] = {}
            current = current[key]
        current[keys[-1]] = value
        
        # Save back
        with open(config_path, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        return True
    except Exception as e:
        logger.error("Failed to save config: %s", e)
        return False
"""
save_config_pattern = re.compile(
    r'def save_config_value\(key_path: str, value: any\) -> bool:\n.*?(?=\n# ============================================================================\n# HermesCLI Class)',
    re.S,
)
save_config_match = save_config_pattern.search(cli_text)
if not save_config_match:
    raise SystemExit("Failed to locate save_config_value in cli.py")
cli_path.write_text(cli_text[:save_config_match.start()] + save_config_guard + cli_text[save_config_match.end():])

def ensure_helper_import(text: str) -> str:
    if "get_hermes_home()" not in text:
        return text
    if re.search(r"from hermes_cli\.config import [^\n]*\bget_hermes_home\b", text):
        return text
    config_import = re.search(r"^from hermes_cli\.config import ([^\n]+)$", text, flags=re.M)
    if config_import:
        return re.sub(
            r"^from hermes_cli\.config import ([^\n]+)$",
            r"from hermes_cli.config import \1, get_hermes_home",
            text,
            count=1,
            flags=re.M,
        )
    if "from pathlib import Path\n" in text:
        return text.replace(
            "from pathlib import Path\n",
            "from pathlib import Path\n\nfrom hermes_cli.config import get_hermes_home\n",
            1,
        )
    return "from hermes_cli.config import get_hermes_home\n" + text


def patch_text(path_str: str, replacements: list[tuple[str, str]]) -> None:
    path = root / path_str
    text = path.read_text()
    original = text
    for old, new in replacements:
        if new in text:
            continue
        candidates = [
            old,
            old.replace('"', "'"),
            old.replace("'", '"'),
        ]
        for candidate in candidates:
            if candidate in text:
                text = text.replace(candidate, new, 1)
                break
    if text != original:
        text = ensure_helper_import(text)
        path.write_text(text)


patch_text(
    "agent/auxiliary_client.py",
    [
        (
            '_AUTH_JSON_PATH = Path.home() / ".hermes" / "auth.json"',
            '_AUTH_JSON_PATH = get_hermes_home() / "auth.json"',
        ),
    ],
)

patch_text(
    "agent/prompt_builder.py",
    [
        (
            '        global_soul = Path.home() / ".hermes" / "SOUL.md"',
            '        global_soul = get_hermes_home() / "SOUL.md"',
        ),
    ],
)

patch_text(
    "cli.py",
    [
        (
            '        path = Path.home() / ".hermes" / path',
            '        path = _hermes_home / path',
        ),
        (
            "    user_config_path = Path.home() / '.hermes' / 'config.yaml'",
            "    user_config_path = _hermes_home / 'config.yaml'",
        ),
        (
            '        self._history_file = Path.home() / ".hermes_history"',
            '        self._history_file = _hermes_home / ".history"',
        ),
        (
            '        img_dir = Path.home() / ".hermes" / "images"',
            '        img_dir = _hermes_home / "images"',
        ),
        (
            '                paste_dir = Path(os.path.expanduser("~/.hermes/pastes"))',
            '                paste_dir = _hermes_home / "pastes"',
        ),
    ],
)

patch_text(
    "gateway/channel_directory.py",
    [
        (
            'DIRECTORY_PATH = Path.home() / ".hermes" / "channel_directory.json"',
            'DIRECTORY_PATH = get_hermes_home() / "channel_directory.json"',
        ),
        (
            '    sessions_path = Path.home() / ".hermes" / "sessions" / "sessions.json"',
            '    sessions_path = get_hermes_home() / "sessions" / "sessions.json"',
        ),
    ],
)

patch_text(
    "gateway/config.py",
    [
        (
            '    sessions_dir: Path = field(default_factory=lambda: Path.home() / ".hermes" / "sessions")',
            '    sessions_dir: Path = field(default_factory=lambda: get_hermes_home() / "sessions")',
        ),
        (
            '        sessions_dir = Path.home() / ".hermes" / "sessions"',
            '        sessions_dir = get_hermes_home() / "sessions"',
        ),
        (
            '    gateway_config_path = Path.home() / ".hermes" / "gateway.json"',
            '    gateway_config_path = get_hermes_home() / "gateway.json"',
        ),
        (
            '        config_yaml_path = Path.home() / ".hermes" / "config.yaml"',
            '        config_yaml_path = get_hermes_home() / "config.yaml"',
        ),
    ],
)

patch_text(
    "gateway/delivery.py",
    [
        (
            '        self.output_dir = Path.home() / ".hermes" / "cron" / "output"',
            '        self.output_dir = get_hermes_home() / "cron" / "output"',
        ),
        (
            '        out_dir = Path.home() / ".hermes" / "cron" / "output"',
            '        out_dir = get_hermes_home() / "cron" / "output"',
        ),
    ],
)

patch_text(
    "gateway/hooks.py",
    [
        (
            'HOOKS_DIR = Path(os.path.expanduser("~/.hermes/hooks"))',
            'HOOKS_DIR = get_hermes_home() / "hooks"',
        ),
    ],
)

patch_text(
    "gateway/mirror.py",
    [
        (
            '_SESSIONS_DIR = Path.home() / ".hermes" / "sessions"',
            '_SESSIONS_DIR = get_hermes_home() / "sessions"',
        ),
    ],
)

patch_text(
    "gateway/pairing.py",
    [
        (
            'PAIRING_DIR = Path(os.path.expanduser("~/.hermes/pairing"))',
            'PAIRING_DIR = get_hermes_home() / "pairing"',
        ),
    ],
)

patch_text(
    "gateway/platforms/base.py",
    [
        (
            'IMAGE_CACHE_DIR = Path(os.path.expanduser("~/.hermes/image_cache"))',
            'IMAGE_CACHE_DIR = get_hermes_home() / "image_cache"',
        ),
        (
            'AUDIO_CACHE_DIR = Path(os.path.expanduser("~/.hermes/audio_cache"))',
            'AUDIO_CACHE_DIR = get_hermes_home() / "audio_cache"',
        ),
        (
            'DOCUMENT_CACHE_DIR = Path(os.path.expanduser("~/.hermes/document_cache"))',
            'DOCUMENT_CACHE_DIR = get_hermes_home() / "document_cache"',
        ),
    ],
)

patch_text(
    "gateway/sticker_cache.py",
    [
        (
            'CACHE_PATH = Path(os.path.expanduser("~/.hermes/sticker_cache.json"))',
            'CACHE_PATH = get_hermes_home() / "sticker_cache.json"',
        ),
    ],
)

patch_text(
    "hermes_cli/status.py",
    [
        (
            'from hermes_cli.config import get_env_path, get_env_value',
            'from hermes_cli.config import get_env_path, get_env_value, get_hermes_home',
        ),
        (
            '    jobs_file = Path.home() / ".hermes" / "cron" / "jobs.json"',
            '    jobs_file = get_hermes_home() / "cron" / "jobs.json"',
        ),
        (
            '    sessions_file = Path.home() / ".hermes" / "sessions" / "sessions.json"',
            '    sessions_file = get_hermes_home() / "sessions" / "sessions.json"',
        ),
    ],
)

patch_text(
    "run_agent.py",
    [
        (
            '        _error_log_dir = Path.home() / ".hermes" / "logs"',
            '        _error_log_dir = get_hermes_home() / "logs"',
        ),
    ],
)

patch_text(
    "tools/environments/base.py",
    [
        (
            '        p = Path.home() / ".hermes" / "sandboxes"',
            '        p = get_hermes_home() / "sandboxes"',
        ),
    ],
)

patch_text(
    "tools/environments/modal.py",
    [
        (
            '_SNAPSHOT_STORE = Path.home() / ".hermes" / "modal_snapshots.json"',
            '_SNAPSHOT_STORE = get_hermes_home() / "modal_snapshots.json"',
        ),
    ],
)

patch_text(
    "tools/environments/singularity.py",
    [
        (
            '_SNAPSHOT_STORE = Path.home() / ".hermes" / "singularity_snapshots.json"',
            '_SNAPSHOT_STORE = get_hermes_home() / "singularity_snapshots.json"',
        ),
    ],
)

patch_text(
    "tools/process_registry.py",
    [
        (
            'CHECKPOINT_PATH = Path(os.path.expanduser("~/.hermes/processes.json"))',
            'CHECKPOINT_PATH = get_hermes_home() / "processes.json"',
        ),
    ],
)

patch_text(
    "tools/tts_tool.py",
    [
        (
            'DEFAULT_OUTPUT_DIR = os.path.expanduser("~/.hermes/audio_cache")',
            'DEFAULT_OUTPUT_DIR = str(get_hermes_home() / "audio_cache")',
        ),
    ],
)

PY

          if ! ${pkgs.gnugrep}/bin/grep -q "TINKER_LOGS_DIR" "$out/tools/rl_training_tool.py"; then
            echo "Failed to patch rl_training_tool.py for writable Tinker paths" >&2
            exit 1
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q "browser automation via Nix PATH" "$out/hermes_cli/doctor.py"; then
            echo "Failed to patch hermes_cli/doctor.py for PATH-based browser diagnostics" >&2
            exit 1
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q "for this Hermes process only" "$out/gateway/run.py"; then
            echo "Failed to patch gateway/run.py for Nix-managed /sethome behavior" >&2
            exit 1
          fi

          if ${pkgs.gnugrep}/bin/grep -q "_handle_model_command" "$out/gateway/run.py"; then
            if ! ${pkgs.gnugrep}/bin/grep -q "for this Hermes process only" "$out/gateway/run.py" || ! ${pkgs.gnugrep}/bin/grep -q "programs.hermes-agent.settings.model.default" "$out/gateway/run.py"; then
              echo "Failed to patch gateway/run.py for Nix-managed /model behavior" >&2
              exit 1
            fi
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q "settings.agent.system_prompt" "$out/gateway/run.py" || ! ${pkgs.gnugrep}/bin/grep -q "SOUL.md file declaratively" "$out/gateway/run.py"; then
            echo "Failed to patch gateway/run.py for Nix-managed /personality behavior" >&2
            exit 1
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q "/update" "$out/gateway/run.py" || ! ${pkgs.gnugrep}/bin/grep -q "disabled in the Nix package" "$out/gateway/run.py"; then
            echo "Failed to patch gateway/run.py for Nix-managed /update behavior" >&2
            exit 1
          fi

          if ! ${pkgs.gnugrep}/bin/grep -q 'key_path in {"agent.system_prompt", "model.default"}' "$out/cli.py"; then
            echo "Failed to patch cli.py for Nix-managed slash-command config guards" >&2
            exit 1
          fi

        '';

        hermes-agent =
          let
            inherit (pkgs)
              bash
              callPackage
              coreutils
              gnugrep
              lib
              python312
              stdenvNoCC
              ;

            python = python312;
            workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = sourceRoot; };
            overlay = workspace.mkPyprojectOverlay {
              sourcePreference = "wheel";
            };
            pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                overlay
              ]
            );

            hermesEnv = pythonSet.mkVirtualEnv "${pname}-virtual-env-${version}" {
              hermes-agent = [
                "cli"
                "cron"
                "mcp"
                "messaging"
                "pty"
                "slack"
              ];
            };

            runtimePath = lib.makeBinPath [
              bash
              coreutils
              gnugrep
            ];
          in
          stdenvNoCC.mkDerivation {
            inherit pname version;
            dontUnpack = true;

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/bin" "$out/share"
              ln -s ${patchedSource} "$out/share/hermes-agent"

              cat > "$out/bin/hermes" <<'EOF'
#!${bash}/bin/bash
set -euo pipefail

export PATH="${runtimePath}:$PATH"
export HERMES_NIX_MANAGED=1
hermes_home="''${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME="$hermes_home"
env_file="$hermes_home/.env"
export TINKER_ATROPOS_ROOT="''${TINKER_ATROPOS_ROOT:-$hermes_home/tinker-atropos}"
export TINKER_LOGS_DIR="''${TINKER_LOGS_DIR:-$hermes_home/logs/rl_training}"
if [ -n "''${PYTHONPATH:-}" ]; then
  export PYTHONPATH="${patchedSource}:$PYTHONPATH"
else
  export PYTHONPATH="${patchedSource}"
fi

if [ "''${WHATSAPP_ENABLED:-}" = "true" ] || ([ -f "$env_file" ] && ${gnugrep}/bin/grep -Eiq '^[[:space:]]*WHATSAPP_ENABLED[[:space:]]*=[[:space:]]*(true|1|yes)[[:space:]]*$' "$env_file"); then
  echo "WhatsApp is not supported in the Nix package yet. Leave WHATSAPP_ENABLED unset or false." >&2
  exit 1
fi

case "''\${1-}" in
  setup|uninstall|update|whatsapp)
    echo "hermes ''\${1} is disabled in the Nix package. Configure Hermes declaratively or edit ~/.hermes manually." >&2
    exit 1
    ;;
  login|logout)
    echo "hermes ''\${1} is disabled in the Nix package. OAuth-backed provider auth is not part of the supported Nix workflow yet." >&2
    exit 1
    ;;
  model|tools)
    echo "hermes ''\${1} is disabled in the Nix package. Set providers, models, and toolsets declaratively through Nix." >&2
    exit 1
    ;;
  config)
    case "''\${2-}" in
      edit|migrate|set)
        echo "hermes config ''\${2} is disabled in the Nix package. Update the generated Nix configuration instead." >&2
        exit 1
        ;;
    esac
    ;;
  gateway)
    case "''\${2-}" in
      install|restart|setup|start|stop|uninstall)
        echo "hermes gateway ''\${2} is disabled in the Nix package. Manage the gateway with Nix/Home Manager instead." >&2
        exit 1
        ;;
    esac
    ;;
esac

exec ${hermesEnv}/bin/python -m hermes_cli.main "$@"
EOF
              chmod +x "$out/bin/hermes"

              cat > "$out/bin/hermes-agent" <<'EOF'
#!${bash}/bin/bash
set -euo pipefail

export PATH="${runtimePath}:$PATH"
export HERMES_NIX_MANAGED=1
hermes_home="''${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME="$hermes_home"
export TINKER_ATROPOS_ROOT="''${TINKER_ATROPOS_ROOT:-$hermes_home/tinker-atropos}"
export TINKER_LOGS_DIR="''${TINKER_LOGS_DIR:-$hermes_home/logs/rl_training}"
if [ -n "''${PYTHONPATH:-}" ]; then
  export PYTHONPATH="${patchedSource}:$PYTHONPATH"
else
  export PYTHONPATH="${patchedSource}"
fi

exec ${hermesEnv}/bin/python -m run_agent "$@"
EOF
              chmod +x "$out/bin/hermes-agent"

              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              "$out/bin/hermes" --help >/dev/null

              blocked_config_output="$("$out/bin/hermes" config set model anthropic/claude-opus-4.6 2>&1 || true)"
              printf '%s\n' "$blocked_config_output" | ${gnugrep}/bin/grep -q "disabled in the Nix package"

              blocked_model_output="$("$out/bin/hermes" model 2>&1 || true)"
              printf '%s\n' "$blocked_model_output" | ${gnugrep}/bin/grep -q "Set providers, models, and toolsets declaratively through Nix"

              blocked_tools_output="$("$out/bin/hermes" tools 2>&1 || true)"
              printf '%s\n' "$blocked_tools_output" | ${gnugrep}/bin/grep -q "Set providers, models, and toolsets declaratively through Nix"

              blocked_login_output="$("$out/bin/hermes" login --provider nous 2>&1 || true)"
              printf '%s\n' "$blocked_login_output" | ${gnugrep}/bin/grep -q "OAuth-backed provider auth is not part of the supported Nix workflow yet"

              blocked_logout_output="$("$out/bin/hermes" logout --provider nous 2>&1 || true)"
              printf '%s\n' "$blocked_logout_output" | ${gnugrep}/bin/grep -q "OAuth-backed provider auth is not part of the supported Nix workflow yet"

sethome_output="$(HOME="$TMPDIR/sethome-home" HERMES_NIX_MANAGED=1 PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
import asyncio
from types import SimpleNamespace
from gateway.run import GatewayRunner
from gateway.config import Platform

self_obj = SimpleNamespace(config=SimpleNamespace(platforms={}))
event = SimpleNamespace(
    source=SimpleNamespace(
        platform=Platform.TELEGRAM,
        chat_id="123456789",
        chat_name="Nix Home",
    )
)

result = asyncio.run(GatewayRunner._handle_set_home_command(self_obj, event))
print(result)
print(self_obj.config.platforms[Platform.TELEGRAM].home_channel.chat_id)
PY
)"
              printf '%s\n' "$sethome_output" | ${gnugrep}/bin/grep -q "for this Hermes process only"
              printf '%s\n' "$sethome_output" | ${gnugrep}/bin/grep -q "TELEGRAM_HOME_CHANNEL=123456789"
              printf '%s\n' "$sethome_output" | ${gnugrep}/bin/grep -q "^123456789$"

              if ${gnugrep}/bin/grep -q "_handle_model_command" "$out/share/hermes-agent/gateway/run.py"; then
model_output="$(HOME="$TMPDIR/model-home" HERMES_NIX_MANAGED=1 PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
import asyncio
from pathlib import Path
from types import SimpleNamespace
from gateway.run import GatewayRunner

home = Path.home() / ".hermes"
home.mkdir(parents=True, exist_ok=True)

source = SimpleNamespace(platform=None, chat_id="123456789", thread_id=None)

class Event:
    source = source

    def get_command_args(self):
        return "anthropic/claude-sonnet-4 --global"

self_obj = SimpleNamespace(
    _session_key_for_source=lambda source: "install-check-model",
)
result = asyncio.run(GatewayRunner._handle_model_command(self_obj, Event()))
config_path = home / "config.yaml"
print(result)
print(config_path.exists())
PY
)"
                printf '%s\n' "$model_output" | ${gnugrep}/bin/grep -q "for this Hermes process only"
                printf '%s\n' "$model_output" | ${gnugrep}/bin/grep -q "settings.model.default"
                printf '%s\n' "$model_output" | ${gnugrep}/bin/grep -q "^False$"
              fi

personality_output="$(HOME="$TMPDIR/personality-home" HERMES_NIX_MANAGED=1 PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
import asyncio
from pathlib import Path
from types import SimpleNamespace
import yaml
from gateway.run import GatewayRunner

home = Path.home() / ".hermes"
home.mkdir(parents=True, exist_ok=True)
config_path = home / "config.yaml"
config_path.write_text(yaml.safe_dump({
    "agent": {
        "personalities": {
            "technical": "You are technical."
        }
    }
}, sort_keys=False))

class Event:
    def get_command_args(self):
        return "technical"

self_obj = SimpleNamespace(_ephemeral_system_prompt="")
result = asyncio.run(GatewayRunner._handle_personality_command(self_obj, Event()))
config = yaml.safe_load(config_path.read_text()) or {}
print(result)
print(self_obj._ephemeral_system_prompt)
print("system_prompt" in (config.get("agent") or {}))
PY
)"
              printf '%s\n' "$personality_output" | ${gnugrep}/bin/grep -q "for this Hermes process only"
              printf '%s\n' "$personality_output" | ${gnugrep}/bin/grep -q "settings.agent.system_prompt"
              printf '%s\n' "$personality_output" | ${gnugrep}/bin/grep -q "^You are technical\.$"
              printf '%s\n' "$personality_output" | ${gnugrep}/bin/grep -q "^False$"

update_output="$(HOME="$TMPDIR/update-home" HERMES_NIX_MANAGED=1 PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
import asyncio
from types import SimpleNamespace
from gateway.run import GatewayRunner
from gateway.config import Platform

event = SimpleNamespace(
    source=SimpleNamespace(
        platform=Platform.TELEGRAM,
        chat_id="123",
        user_id="456",
    )
)

print(asyncio.run(GatewayRunner._handle_update_command(SimpleNamespace(), event)))
PY
)"
              printf '%s\n' "$update_output" | ${gnugrep}/bin/grep -q "/update"
              printf '%s\n' "$update_output" | ${gnugrep}/bin/grep -q "disabled in the Nix package"

cli_guard_output="$(HOME="$TMPDIR/cli-home" HERMES_NIX_MANAGED=1 PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
from pathlib import Path
import yaml
from cli import save_config_value

home = Path.home() / ".hermes"
home.mkdir(parents=True, exist_ok=True)
config_path = home / "config.yaml"
config_path.write_text(yaml.safe_dump({"model": {"default": "before"}}, sort_keys=False))

result = save_config_value("model.default", "after")
config = yaml.safe_load(config_path.read_text()) or {}
print(result)
print(config["model"]["default"])
PY
)"
              printf '%s\n' "$cli_guard_output" | ${gnugrep}/bin/grep -q "^False$"
              printf '%s\n' "$cli_guard_output" | ${gnugrep}/bin/grep -q "^before$"

              tmp_home="$TMPDIR/hermes-home"
              mkdir -p "$tmp_home/.hermes" "$TMPDIR/bin"
              cat > "$TMPDIR/bin/agent-browser" <<'EOF'
#!/bin/sh
exit 0
EOF
              chmod +x "$TMPDIR/bin/agent-browser"

doctor_output="$(HOME="$tmp_home" PATH="$TMPDIR/bin:$PATH" "$out/bin/hermes" doctor 2>&1 || true)"
              printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "browser automation via Nix PATH"

              if printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "run: npm install"; then
                echo "doctor still suggested npm install under Nix-managed browser tooling" >&2
                printf '%s\n' "$doctor_output" >&2
                exit 1
              fi

              if printf '%s\n' "$doctor_output" | ${gnugrep}/bin/grep -q "Node.js not found"; then
                echo "doctor still warned about missing Node.js with PATH-provided agent-browser" >&2
                printf '%s\n' "$doctor_output" >&2
                exit 1
              fi

hermes_home_output="$(HOME="$TMPDIR/real-home" HERMES_HOME="$TMPDIR/custom-hermes" PYTHONPATH="$out/share/hermes-agent" ${hermesEnv}/bin/python - <<'PY'
from gateway.channel_directory import DIRECTORY_PATH
from gateway.config import GatewayConfig
from gateway.pairing import PAIRING_DIR
from gateway.sticker_cache import CACHE_PATH
from tools.rl_training_tool import CONFIGS_DIR as RL_CONFIGS_DIR
from tools.rl_training_tool import LOGS_DIR as RL_LOGS_DIR
from tools.rl_training_tool import TINKER_ATROPOS_ROOT as RL_TINKER_ATROPOS_ROOT
from tools.environments.base import get_sandbox_dir
from tools.process_registry import CHECKPOINT_PATH
from tools.tts_tool import DEFAULT_OUTPUT_DIR

cfg = GatewayConfig()
print(cfg.sessions_dir)
print(PAIRING_DIR)
print(DIRECTORY_PATH)
print(CACHE_PATH)
print(CHECKPOINT_PATH)
print(DEFAULT_OUTPUT_DIR)
print(get_sandbox_dir())
print(RL_TINKER_ATROPOS_ROOT)
print(RL_CONFIGS_DIR)
print(RL_LOGS_DIR)
PY
)"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/sessions"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/platforms/pairing"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/channel_directory.json"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/sticker_cache.json"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/processes.json"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/cache/audio"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/sandboxes"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/tinker-atropos"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/tinker-atropos/configs"
              printf '%s\n' "$hermes_home_output" | ${gnugrep}/bin/grep -q "$TMPDIR/custom-hermes/logs/rl_training"

              runHook postInstallCheck
            '';

            meta = with pkgs.lib; {
              description = "Hermes Agent - self-improving AI agent";
              homepage = "https://github.com/NousResearch/hermes-agent";
              license = licenses.mit;
              mainProgram = "hermes";
              platforms = [ "aarch64-linux" "x86_64-linux" ];
              sourceProvenance = with sourceTypes; [ fromSource ];
            };
          };
      in
      {
        packages = {
          default = hermes-agent;
          inherit hermes-agent;
        };

        apps = {
          default = {
            type = "app";
            program = "${hermes-agent}/bin/hermes";
          };
          hermes = {
            type = "app";
            program = "${hermes-agent}/bin/hermes";
          };
          hermes-agent = {
            type = "app";
            program = "${hermes-agent}/bin/hermes-agent";
          };
        };
      }
    );
}
