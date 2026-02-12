#!/usr/bin/env bash
# Setup IoTeX AI Gateway for OpenClaw
#
# Non-interactive (all params):
#   curl -fsSL URL | bash -s -- API_KEY [MODEL] [AUDIO_MODEL] [--default]
#
# Interactive:
#   curl -fsSL URL | bash
#   bash openclaw-setup-iotex-ai.sh
#
# Examples:
#   bash openclaw-setup-iotex-ai.sh sk-xxx                                          # defaults
#   bash openclaw-setup-iotex-ai.sh sk-xxx gemini-2.5-flash                         # pick LLM
#   bash openclaw-setup-iotex-ai.sh sk-xxx gemini-2.5-flash-lite whisper-1 --default # full
#
set -euo pipefail

# ── Available models ──────────────────────────────────────────────────
LLM_MODELS=(
  "gemini-2.5-flash-lite|Gemini 2.5 Flash Lite|Google|\$0.10/\$0.40 per 1M tokens"
  "gemini-2.5-flash|Gemini 2.5 Flash|Google|\$0.30/\$2.50 per 1M tokens"
)

AUDIO_MODELS=(
  "openai/whisper-large-v3-turbo|Whisper Large V3 Turbo (fast)|OpenAI|\$0.0015/min"
  "openai/whisper-large-v3|Whisper Large V3 (standard)|OpenAI|\$0.0030/min"
  "whisper-1|Whisper 1 (legacy)|OpenAI|\$0.0060/min"
)

# ── Collect known model IDs for validation ───────────────────────────
known_llm_ids() {
  for entry in "${LLM_MODELS[@]}"; do
    IFS='|' read -r id _ <<< "$entry"
    echo "$id"
  done
}

known_audio_ids() {
  for entry in "${AUDIO_MODELS[@]}"; do
    IFS='|' read -r id _ <<< "$entry"
    echo "$id"
  done
}

# ── Parse args ────────────────────────────────────────────────────────
API_KEY=""
LLM_MODEL=""
AUDIO_MODEL=""
SET_DEFAULT=false

for arg in "$@"; do
  case "$arg" in
    --default) SET_DEFAULT=true ;;
    sk-*)      API_KEY="$arg" ;;
    *)
      if [ -z "$LLM_MODEL" ]; then
        LLM_MODEL="$arg"
      elif [ -z "$AUDIO_MODEL" ]; then
        AUDIO_MODEL="$arg"
      fi
      ;;
  esac
done

# ── Interactive prompts ───────────────────────────────────────────────
pick_from_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local count=${#options[@]}

  echo ""
  echo "$prompt"
  echo ""
  for i in "${!options[@]}"; do
    IFS='|' read -r id name _provider price <<< "${options[$i]}"
    local num=$((i + 1))
    local marker=""
    if [ "$num" -eq 1 ]; then marker=" (recommended)"; fi
    printf "  %d) %-45s %s%s\n" "$num" "$name ($id)" "$price" "$marker"
  done
  echo ""

  local choice
  printf "Choose [1-%d, default=1]: " "$count"
  read -r choice </dev/tty 2>/dev/null || choice=""
  choice="${choice:-1}"

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    choice=1
  fi

  IFS='|' read -r PICKED_ID _ <<< "${options[$((choice - 1))]}"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local yn
  if [ "$default" = "y" ]; then
    printf "%s [Y/n]: " "$prompt"
  else
    printf "%s [y/N]: " "$prompt"
  fi
  read -r yn </dev/tty 2>/dev/null || yn=""
  yn="${yn:-$default}"
  case "$yn" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

if [ -z "$API_KEY" ]; then
  echo ""
  echo "  IoTeX AI Gateway — OpenClaw Setup"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  printf "  API key (get one at https://gateway.iotex.ai/console/token): "
  read -r API_KEY </dev/tty 2>/dev/null || API_KEY=""
fi

if [ -z "$API_KEY" ]; then
  echo "Error: API key is required."
  exit 1
fi

if [ -z "$LLM_MODEL" ]; then
  pick_from_menu "Select an LLM model:" "${LLM_MODELS[@]}"
  LLM_MODEL="$PICKED_ID"
fi

if [ -z "$AUDIO_MODEL" ]; then
  pick_from_menu "Select an audio transcription model:" "${AUDIO_MODELS[@]}"
  AUDIO_MODEL="$PICKED_ID"
fi

# ── Validate model names ────────────────────────────────────────────
if ! known_llm_ids | grep -qxF "$LLM_MODEL"; then
  echo "Error: Unknown LLM model '$LLM_MODEL'."
  echo "Supported models:"
  known_llm_ids | sed 's/^/  - /'
  exit 1
fi

if ! known_audio_ids | grep -qxF "$AUDIO_MODEL"; then
  echo "Error: Unknown audio model '$AUDIO_MODEL'."
  echo "Supported models:"
  known_audio_ids | sed 's/^/  - /'
  exit 1
fi

if [ "$SET_DEFAULT" = false ] && [ -t 0 ]; then
  echo ""
  if ask_yes_no "  Set iotex/$LLM_MODEL as your default model?" "n"; then
    SET_DEFAULT=true
  fi
fi

# ── Preflight checks ─────────────────────────────────────────────────
if ! command -v openclaw &>/dev/null; then
  echo "Error: openclaw not found. Install it first: npm install -g openclaw"
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "Error: node not found. OpenClaw requires Node.js."
  exit 1
fi

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CONFIG="$OPENCLAW_DIR/openclaw.json"
if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'openclaw onboard' first."
  exit 1
fi

# ── Apply config (deep merge via node, reads key from env) ───────────
echo ""
echo "==> Updating openclaw.json..."

IOTEX_SETUP_KEY="$API_KEY" node -e '
const fs = require("fs");
const configPath = process.argv[1];
const apiKey     = process.env.IOTEX_SETUP_KEY;
const llmModel   = process.argv[2];
const audioModel = process.argv[3];
const setDefault = process.argv[4] === "true";

const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));

// All available IoTeX LLM models
const allModels = [
  { id: "gemini-2.5-flash-lite", reasoning: false, contextWindow: 200000, maxTokens: 8192 },
  { id: "gemini-2.5-flash", reasoning: false, contextWindow: 200000, maxTokens: 8192 },
];

// 1. Add iotex provider with all models (preserves other providers)
config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.models.providers.iotex = {
  baseUrl: "https://gateway.iotex.ai/v1",
  apiKey: apiKey,
  api: "openai-completions",
  models: allModels.map(m => ({
    ...m,
    name: m.id + " (via IoTeX)",
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  }))
};

// 2. Register all models so they appear in /models list
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.models = config.agents.defaults.models || {};
for (const m of allModels) {
  const key = "iotex/" + m.id;
  if (!config.agents.defaults.models[key]) {
    config.agents.defaults.models[key] = {};
  }
}

// 3. Set as default model (only if requested)
if (setDefault) {
  config.agents.defaults.model = config.agents.defaults.model || {};
  config.agents.defaults.model.primary = "iotex/" + llmModel;
}

// 4. Add auth profile (preserves other profiles)
config.auth = config.auth || {};
config.auth.profiles = config.auth.profiles || {};
config.auth.profiles["iotex:default"] = { provider: "iotex", mode: "api_key" };

// 5. Add audio model (append if not already present, preserve existing)
config.tools = config.tools || {};
config.tools.media = config.tools.media || {};
config.tools.media.audio = config.tools.media.audio || {};
config.tools.media.audio.enabled = true;
config.tools.media.audio.models = config.tools.media.audio.models || [];

const iotexAudio = {
  provider: "openai",
  model: audioModel,
  baseUrl: "https://gateway.iotex.ai/v1",
  profile: "iotex:default",
  type: "provider"
};

// Replace existing iotex audio entry or append
const idx = config.tools.media.audio.models.findIndex(
  m => m.baseUrl === "https://gateway.iotex.ai/v1" || m.profile === "iotex:default"
);
if (idx >= 0) {
  config.tools.media.audio.models[idx] = iotexAudio;
} else {
  config.tools.media.audio.models.push(iotexAudio);
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
' "$CONFIG" "$LLM_MODEL" "$AUDIO_MODEL" "$SET_DEFAULT"

# ── Set up auth profile credentials ─────────────────────────────────
echo "==> Setting up auth profile..."
AGENT_DIR="$OPENCLAW_DIR/agents/main/agent"
mkdir -p "$AGENT_DIR"
AUTH_FILE="$AGENT_DIR/auth-profiles.json"

IOTEX_SETUP_KEY="$API_KEY" node -e '
const fs = require("fs");
const file = process.argv[1];
const key  = process.env.IOTEX_SETUP_KEY;
let store = { version: 1, profiles: {} };
try { store = JSON.parse(fs.readFileSync(file, "utf-8")); } catch {}
store.profiles = store.profiles || {};
store.profiles["iotex:default"] = { type: "api_key", provider: "iotex", key };
fs.writeFileSync(file, JSON.stringify(store, null, 2) + "\n");
' "$AUTH_FILE"

# ── Restart ──────────────────────────────────────────────────────────
echo "==> Restarting gateway..."
if ! openclaw gateway restart 2>/dev/null; then
  echo ""
  echo "  Warning: Gateway restart failed. Run manually:"
  echo "    openclaw gateway restart"
  echo ""
  exit 1
fi
sleep 3

echo ""
echo "  Done! IoTeX AI Gateway is configured."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  LLM:    iotex/$LLM_MODEL"
echo "  Audio:  $AUDIO_MODEL (auto-transcribes voice messages)"
if [ "$SET_DEFAULT" = true ]; then
  echo "  Default model set to: iotex/$LLM_MODEL"
else
  echo ""
  echo "  To set as default model:"
  echo "    openclaw config set agents.defaults.model.primary 'iotex/$LLM_MODEL'"
fi
echo ""
echo "  Switch models in chat:  /model iotex/$LLM_MODEL"
echo "  Verify:                 openclaw gateway health"
echo ""
