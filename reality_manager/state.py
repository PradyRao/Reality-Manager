from __future__ import annotations

from dataclasses import asdict
import json
from pathlib import Path
from typing import Any

from platformdirs import user_config_dir

from .ssh_client import SSHConfig

APP_NAME = "Reality Manager"
APP_AUTHOR = "RealityManager"


def config_path() -> Path:
    p = Path(user_config_dir(APP_NAME, APP_AUTHOR))
    p.mkdir(parents=True, exist_ok=True)
    return p / "settings.json"


def load_settings() -> dict[str, Any]:
    p = config_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_settings(settings: dict[str, Any]) -> None:
    p = config_path()
    p.write_text(json.dumps(settings, indent=2), encoding="utf-8")


def public_ssh_dict(cfg: SSHConfig) -> dict[str, Any]:
    d = asdict(cfg)
    d.pop("password", None)
    d.pop("key_passphrase", None)
    d.pop("sudo_password", None)
    return d
