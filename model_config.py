"""Shared model catalog loader — single source of truth from models.yaml.

Usage from Python:
    from model_config import load_config, load_models, resolve_model_id

Usage from PowerShell (outputs JSON to stdout):
    $json = python model_config.py | ConvertFrom-Json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import yaml

_CONFIG_PATH = Path(__file__).resolve().parent / "models.yaml"

_cache: dict[str, Any] | None = None


def load_config(config_path: Path | str | None = None) -> dict[str, Any]:
    """Load and cache the full models.yaml config."""
    global _cache
    if _cache is not None and config_path is None:
        return _cache
    path = Path(config_path) if config_path else _CONFIG_PATH
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if config_path is None:
        _cache = data
    return data


def load_models(config_path: Path | str | None = None) -> dict[str, dict[str, Any]]:
    """Return the models dict keyed by model id."""
    return load_config(config_path).get("models", {})


def default_model_id(config_path: Path | str | None = None) -> str:
    return load_config(config_path).get("default_model", "qwen36")


def resolve_model_id(name: str, config_path: Path | str | None = None) -> str | None:
    """Resolve a model id or alias to the canonical model id."""
    models = load_models(config_path)
    if name in models:
        return name
    for model_id, model in models.items():
        if name in model.get("aliases", []):
            return model_id
    return None


def valid_model_ids(config_path: Path | str | None = None) -> list[str]:
    """Return all valid model ids (canonical + aliases)."""
    models = load_models(config_path)
    ids = list(models.keys())
    for model in models.values():
        ids.extend(model.get("aliases", []))
    return ids


def model_catalog_for_api(config_path: Path | str | None = None) -> list[dict[str, Any]]:
    """Return the model catalog in the format served by /admin/models."""
    models = load_models(config_path)
    return [
        {
            "id": model_id,
            "label": m.get("label", model_id),
            "aliases": m.get("aliases", []),
            "model_file": m.get("file", ""),
            "default_context": m.get("context", 262144),
            "default_kv_cache": m.get("kv_cache", "q8_0"),
            "moe": m.get("moe", False),
            "kv_offload": m.get("kv_offload", False),
            "repack": m.get("repack", False),
            "cache_ram": m.get("cache_ram", 0),
            "ctx_checkpoints": m.get("ctx_checkpoints", 0),
            "checkpoint_min_step": m.get("checkpoint_min_step", 0),
            "batch_size": m.get("batch_size", 2048),
            "ubatch_size": m.get("ubatch_size", 2048),
        }
        for model_id, m in models.items()
    ]


if __name__ == "__main__":
    config = load_config()
    json.dump(config, sys.stdout, indent=2)
    sys.stdout.write("\n")
