#!/usr/bin/env bash
#
# Seed OpenHands V1 persisted settings so the USAi provider works without
# manual entry in the Settings UI on first launch.
#
# OpenHands V1 (the GUI/agent-server image) stores its configuration in
# $OH_PERSISTENCE_DIR/settings.json (defaults to ~/.openhands/settings.json).
# The custom Base URL needed for USAi cannot be supplied by environment
# variables to the GUI, so we pre-seed the persisted settings file.
#
# Usage:
#   OPENAI_API_KEY=<usai-key> OPENHANDS_MODEL=openai/<model> \
#     scripts/seed-openhands-settings.sh
#
# Inputs (environment variables):
#   OPENAI_API_KEY  - USAi API key (required)
#   OPENHANDS_MODEL - LiteLLM model id, e.g. openai/gpt-5.4-... (required)
#   USAI_BASE_URL   - USAi endpoint (default: https://api.gsa.usai.gov/api/v1)
#   OH_PERSISTENCE_DIR - OpenHands state dir (default: ~/.openhands)
#
# This script never prints the API key. It writes the settings file with
# restrictive permissions (0600).

set -euo pipefail

USAI_BASE_URL="${USAI_BASE_URL:-https://api.gsa.usai.gov/api/v1}"
PERSIST_DIR="${OH_PERSISTENCE_DIR:-$HOME/.openhands}"
SETTINGS_FILE="$PERSIST_DIR/settings.json"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY is not set." >&2
  echo "  Export your USAi key first: export OPENAI_API_KEY=<your-usai-key>" >&2
  exit 1
fi

if [ -z "${OPENHANDS_MODEL:-}" ]; then
  echo "ERROR: OPENHANDS_MODEL is not set." >&2
  echo "  Example: export OPENHANDS_MODEL=openai/gpt-5.4-latest-guardrails-defaultv2" >&2
  exit 1
fi

mkdir -p "$PERSIST_DIR"

# Build settings.json. The schema mirrors the OpenHands V1 persisted-settings
# baselines:
#   - top-level Settings.schema_version = 2
#   - agent_settings (OpenHandsAgentSettings) with schema_version = 4
#   - agent_settings.llm carries model / base_url / api_key (LiteLLM LLM model)
# A "Default" llm_profile is seeded so the Settings UI shows the active config.
#
# We use python3 for robust JSON encoding (handles key escaping safely and
# keeps the API key out of the process argument list / logs).
OPENAI_API_KEY="$OPENAI_API_KEY" \
OPENHANDS_MODEL="$OPENHANDS_MODEL" \
USAI_BASE_URL="$USAI_BASE_URL" \
SETTINGS_FILE="$SETTINGS_FILE" \
python3 - <<'PY'
import json
import os

model = os.environ["OPENHANDS_MODEL"]
base_url = os.environ["USAI_BASE_URL"]
api_key = os.environ["OPENAI_API_KEY"]
settings_file = os.environ["SETTINGS_FILE"]

llm = {
    "model": model,
    "base_url": base_url,
    "api_key": api_key,
}

agent_settings = {
    "schema_version": 4,
    "agent_kind": "openhands",
    "agent": "CodeActAgent",
    "llm": llm,
    "tools": [{"name": "TerminalTool", "params": {}}],
}

settings = {
    "schema_version": 2,
    "v1_enabled": True,
    "agent_settings": agent_settings,
    "conversation_settings": {
        "schema_version": 1,
        "max_iterations": 100,
    },
    "llm_profiles": {
        "profiles": {"Default": llm},
        "active": "Default",
    },
}

# Preserve any pre-existing non-LLM settings (e.g. git identity) if present.
existing = {}
if os.path.exists(settings_file):
    try:
        with open(settings_file, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
    except (json.JSONDecodeError, OSError):
        existing = {}

for key in ("language", "git_user_name", "git_user_email"):
    if key in existing:
        settings[key] = existing[key]

with open(settings_file, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
PY

chmod 600 "$SETTINGS_FILE"

echo "  OpenHands settings seeded: $SETTINGS_FILE"
echo "  Provider: USAi ($USAI_BASE_URL)"
echo "  Model:    $OPENHANDS_MODEL"
