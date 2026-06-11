"""Installation and first-run configuration integration tests."""

import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path


REPO = Path(__file__).parent.parent.parent


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_generated_hook_command_executes_with_spaces(tmp_path):
    generator = _load_module(
        "generate_hook_command",
        REPO / "scripts" / "generate_hook_command.py",
    )
    root = tmp_path / "install path with spaces"
    root.mkdir()
    config = root / "config file.json"
    config.write_text("{}")
    hook = root / "print env.py"
    hook.write_text(
        "import os\n"
        "print(os.environ['THENOW_CONFIG_PATH'])\n"
    )

    command = generator.generate(str(config), sys.executable, str(hook))
    result = subprocess.run(command, shell=True, capture_output=True, text=True)

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(config)


def test_generate_config_updates_empty_relay_url_and_preserves_api_key(tmp_path, monkeypatch):
    module = _load_module("generate_config_relay", REPO / "broker" / "generate_config.py")
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"api_key": "keep-me", "relay_url": ""}))
    module.CONFIG_PATH = str(config)
    monkeypatch.setenv("CHITNOW_RELAY_URL", "https://relay.example.com")

    result = module.ensure_config()

    assert result["api_key"] == "keep-me"
    assert result["relay_url"] == "https://relay.example.com"
    assert len(result["pairing_bootstrap_secret"]) == 64
    assert stat.S_IMODE(config.stat().st_mode) == 0o600


def test_generate_config_preserves_existing_relay_without_env(tmp_path, monkeypatch):
    module = _load_module("generate_config_preserve", REPO / "broker" / "generate_config.py")
    config = tmp_path / "config.json"
    config.write_text(json.dumps({
        "api_key": "keep-me",
        "relay_url": "https://existing.example.com",
        "pairing_bootstrap_secret": "a" * 64,
    }))
    module.CONFIG_PATH = str(config)
    monkeypatch.delenv("CHITNOW_RELAY_URL", raising=False)

    result = module.ensure_config()

    assert result["relay_url"] == "https://existing.example.com"
    assert result["pairing_bootstrap_secret"] == "a" * 64


def test_install_script_uses_health_check_and_safe_hook_generator():
    install = (REPO / "install.sh").read_text()
    assert "scripts/generate_hook_command.py" in install
    assert "curl -sk --max-time 2 https://localhost:8000/health" in install
    assert "Broker failed to start" in install
