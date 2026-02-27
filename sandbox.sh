#!/usr/bin/env bash
# sandbox.sh — Docker Desktop sandbox lifecycle for AI coding agents
# Usage: ./sandbox.sh {setup|run|validate|clean|encrypt|decrypt}
set -euo pipefail

# --- Source centralized config ---

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

# --- Config (overridable via environment, defaults from config.sh) ---

SANDBOX_NAME="${SANDBOX_NAME:-$DEFAULT_SANDBOX_NAME}"
CONFIG_DIR="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
AUDIT_LOG="${AUDIT_LOG:-${CONFIG_DIR}/audit.log}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-$DEFAULT_KEYCHAIN_SERVICE}"
ENV_ENC="${ENV_ENC:-$DEFAULT_ENV_ENC}"
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
NETWORK_POLICY="${NETWORK_POLICY:-$DEFAULT_NETWORK_POLICY}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-$DEFAULT_SANDBOX_MEMORY}"
SANDBOX_CPUS="${SANDBOX_CPUS:-$DEFAULT_SANDBOX_CPUS}"

# --- Platform guard ---

if [[ "$(uname -s)" != "$REQUIRED_PLATFORM" ]]; then
	printf 'ERROR: agent-sandbox requires macOS (uses Keychain for secret storage).\n' >&2
	exit 1
fi

# --- Helpers ---

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() {
	log "ERROR: $*" >&2
	exit 1
}
audit() {
	mkdir -p "$CONFIG_DIR"
	printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "${2:-}" >>"$AUDIT_LOG"
	chmod 600 "$AUDIT_LOG" 2>/dev/null || true
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || err "$1 not found. Install with: $2"
}

# SOPS wrappers — centralize format flags (SOPS doesn't auto-detect .env.enc as dotenv)
# shellcheck disable=SC2086  # Intentional word splitting on SOPS_FORMAT_FLAGS
sops_encrypt() { sops encrypt $SOPS_FORMAT_FLAGS "$@"; }
# shellcheck disable=SC2086
sops_decrypt() { sops decrypt $SOPS_FORMAT_FLAGS "$@"; }

check_keychain_access() {
	if ! security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
		err "Cannot retrieve AGE key from Keychain. The keychain may be locked.
  Try: security unlock-keychain ~/Library/Keychains/login.keychain-db
  Or re-run: make setup"
	fi
}

# Load .env file into environment if key vars are not already set
# Respects existing environment variables (won't override if already exported)
load_env() {
	if [[ -n "${OPENAI_COMPAT_BASE_URL:-}" ]]; then
		return 0 # Already set in environment, nothing to do
	fi
	if [[ -f "$ENV_FILE" ]]; then
		log "Loading settings from ${ENV_FILE}..."
		# Export each KEY=VALUE line, skipping comments and empty lines
		while IFS='=' read -r key value; do
			key=$(echo "$key" | tr -d '[:space:]')
			[[ -z "$key" || "$key" == \#* ]] && continue
			# Only export if not already set in environment
			if [[ -z "${!key:-}" ]]; then
				export "$key=$value"
			fi
		done <"$ENV_FILE"
	elif [[ -f "$ENV_ENC" ]]; then
		log "Found ${ENV_ENC} but no ${ENV_FILE}. Run 'make decrypt' first, or export vars directly."
		return 1
	else
		return 1 # No .env file, caller will show appropriate error
	fi
}

# --- Subcommands ---

cmd_setup() {
	log "Checking prerequisites..."
	local tool_entry cmd hint
	for tool_entry in "${REQUIRED_TOOLS[@]}"; do
		cmd="${tool_entry%%:*}"
		hint="${tool_entry#*:}"
		require_cmd "$cmd" "$hint"
	done

	# Verify Docker sandbox support
	docker sandbox ls >/dev/null 2>&1 || err "Docker sandbox not available. Requires Docker Desktop ${DOCKER_MIN_VERSION}+"

	# Generate AGE key if not in Keychain
	if security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
		log "AGE key already in Keychain"
	else
		log "Generating AGE key pair..."
		local keygen_output
		keygen_output=$(age-keygen 2>&1)
		local private_key public_key
		private_key=$(echo "$keygen_output" | grep '^AGE-SECRET-KEY-' | head -1)
		public_key=$(echo "$keygen_output" | grep 'public key:' | awk '{print $NF}')

		# Validate key format before storing
		if [[ -z "$private_key" || ! "$private_key" =~ $AGE_PRIVATE_KEY_REGEX ]]; then
			err "age-keygen produced unexpected output — private key not found or malformed"
		fi
		if [[ -z "$public_key" || ! "$public_key" =~ $AGE_PUBLIC_KEY_REGEX ]]; then
			err "age-keygen produced unexpected output — public key not found or malformed"
		fi

		security add-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" \
			-w "$private_key" -T /usr/bin/security -U
		log "AGE private key stored in macOS Keychain (service: $KEYCHAIN_SERVICE)"

		# Write .sops.yaml with public key
		cat >.sops.yaml <<SOPS
creation_rules:
  - age: "${public_key}"
SOPS
		log "Created .sops.yaml with public key: ${public_key}"
	fi

	# Create .env from example if missing
	if [[ ! -f "$ENV_FILE" && -f ".env.example" ]]; then
		cp .env.example "$ENV_FILE"
		log "Created .env from .env.example — edit it with your API keys"
	fi

	log "Setup complete. Next: edit .env, then run 'make encrypt'"
	audit "setup" "completed"
}

cmd_encrypt() {
	[[ -f "$ENV_FILE" ]] || err "${ENV_FILE} not found. Copy .env.example and fill in your keys."
	[[ -f ".sops.yaml" ]] || err ".sops.yaml not found. Run 'make setup' first."

	# Validate .sops.yaml has a real key, not the placeholder
	if grep -q "$PLACEHOLDER_KEY" .sops.yaml; then
		err ".sops.yaml still has placeholder key. Run 'make setup' to generate a real AGE key."
	fi

	# Atomic write: encrypt to temp file, then move (prevents data loss on sops failure)
	sops_encrypt "$ENV_FILE" >"${ENV_ENC}.tmp"
	mv "${ENV_ENC}.tmp" "$ENV_ENC"
	rm -f "$ENV_FILE"
	log "Encrypted .env → .env.enc (plaintext .env removed)"
	audit "encrypt" ".env.enc created"
}

cmd_decrypt() {
	[[ -f "$ENV_ENC" ]] || err "${ENV_ENC} not found. Nothing to decrypt."

	check_keychain_access

	SOPS_AGE_KEY=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w)
	export SOPS_AGE_KEY
	# Atomic write: decrypt to temp file, then move (prevents empty .env on sops failure)
	if ! (
		umask 077
		sops_decrypt "$ENV_ENC" >"${ENV_FILE}.tmp"
	); then
		rm -f "${ENV_FILE}.tmp"
		unset SOPS_AGE_KEY
		err "Decryption failed. Check that .env.enc is valid and your AGE key is correct."
	fi
	mv "${ENV_FILE}.tmp" "$ENV_FILE"
	unset SOPS_AGE_KEY
	log "Decrypted .env.enc → .env (mode 600, remember to re-encrypt after editing)"
	audit "decrypt" ".env decrypted for editing"
}

cmd_run() {
	local repo_path="${1:-.}"
	repo_path=$(cd "$repo_path" && pwd)

	[[ -f "$ENV_ENC" ]] || err "${ENV_ENC} not found. Run 'make encrypt' first."
	[[ -f "$NETWORK_POLICY" ]] || err "$NETWORK_POLICY not found."

	cmd_validate || exit 1

	log "Decrypting secrets to temp file (mode 600, auto-deleted on exit)..."
	check_keychain_access
	SOPS_AGE_KEY=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w)
	export SOPS_AGE_KEY

	# Create temp env file with restrictive permissions (umask applies to mktemp)
	# Use a global variable for trap cleanup
	local saved_umask
	saved_umask=$(umask)
	umask 077
	SANDBOX_ENV_TMP=$(mktemp "${TMPDIR:-/tmp}/sandbox-env-XXXXXX")
	umask "$saved_umask"
	trap 'rm -f "$SANDBOX_ENV_TMP"' EXIT INT TERM HUP QUIT PIPE

	sops_decrypt "$ENV_ENC" >"$SANDBOX_ENV_TMP"

	# Prevent SOPS key from leaking to child processes
	unset SOPS_AGE_KEY

	# Inject git identity (sanitized — strip dangerous chars, restrict to safe set)
	local git_name git_email
	git_name=$(git config --global user.name 2>/dev/null | tr -d '\n\r\0' | tr -dc '[:alnum:] ._@-' || echo "Agent")
	git_email=$(git config --global user.email 2>/dev/null | tr -d '\n\r\0' | tr -dc '[:alnum:]._@+-' || echo "agent@sandbox")
	{
		printf 'GIT_AUTHOR_NAME="%s"\n' "$git_name"
		printf 'GIT_AUTHOR_EMAIL="%s"\n' "$git_email"
		printf 'GIT_COMMITTER_NAME="%s"\n' "$git_name"
		printf 'GIT_COMMITTER_EMAIL="%s"\n' "$git_email"
	} >>"$SANDBOX_ENV_TMP"

	log "Creating sandbox '${SANDBOX_NAME}' with repo: ${repo_path}"
	audit "run:start" "repo=${repo_path}"

	# Copy opencode.json to the repo if it exists in agent-sandbox and repo is different
	local config_file="${OPENCODE_CONFIG:-$DEFAULT_OPENCODE_CONFIG}"
	local json_file="${config_file%.jsonc}.json"
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

	# Only copy if script_dir and repo_path are different directories
	if [[ "$script_dir" != "$repo_path" ]]; then
		# Prefer opencode.json over opencode.jsonc for better compatibility
		if [[ -f "${script_dir}/${json_file}" ]]; then
			cp "${script_dir}/${json_file}" "${repo_path}/${json_file}"
			log "Copied ${json_file} to ${repo_path}"
		elif [[ -f "${script_dir}/${config_file}" ]]; then
			cp "${script_dir}/${config_file}" "${repo_path}/${config_file}"
			log "Copied ${config_file} to ${repo_path}"
		fi
	fi

	# Create sandbox (opencode agent, workspace = repo_path)
	docker sandbox create --name "$SANDBOX_NAME" opencode "$repo_path"

	# Apply network blocks using Docker sandbox network proxy
	# Reads both IPv4 and IPv6 CIDRs from network-policy.json via jq
	local all_cidrs
	if ! all_cidrs=$(jq -r '(.blockCidrs // [])[] , (.blockCidrsIpv6 // [])[]' "$NETWORK_POLICY"); then
		docker sandbox stop "$SANDBOX_NAME" 2>/dev/null || true
		docker sandbox rm "$SANDBOX_NAME" 2>/dev/null || true
		err "Failed to parse $NETWORK_POLICY — ensure it is valid JSON"
	fi
	local block_count=0
	local fail_count=0

	if [[ -n "$all_cidrs" ]]; then
		while IFS= read -r cidr; do
			if docker sandbox network proxy "$SANDBOX_NAME" --block-cidr "$cidr" 2>/dev/null; then
				block_count=$((block_count + 1))
			else
				log "WARN: Failed to block CIDR ${cidr}"
				fail_count=$((fail_count + 1))
			fi
		done <<<"$all_cidrs"
		if [[ "$fail_count" -gt 0 ]]; then
			docker sandbox stop "$SANDBOX_NAME" 2>/dev/null || true
			docker sandbox rm "$SANDBOX_NAME" 2>/dev/null || true
			err "Network policy failed: ${fail_count} CIDR blocks could not be applied. Sandbox removed for safety."
		fi
		log "Network policy applied (${block_count} blocks configured)"
	fi

	# Launch interactive session with env vars from temp file
	# Use -w to set working directory to the mounted repo path
	docker sandbox exec -it --env-file "$SANDBOX_ENV_TMP" -w "$repo_path" "$SANDBOX_NAME" opencode

	audit "run:stop" "repo=${repo_path}"
	log "Session ended"
}

cmd_validate() {
	local ok=true

	log "Validating environment..."

	if ! docker sandbox ls >/dev/null 2>&1; then
		log "FAIL: Docker sandbox not available"
		ok=false
	else
		log "OK: Docker sandbox available"
	fi

	# Check Docker version if available
	if docker info >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
		local docker_version
		docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null | grep -oE "[0-9]+\.[0-9]+" | head -1)
		if [[ -n "$docker_version" ]]; then
			local min_version="$DOCKER_MIN_VERSION"
			local current_major minor
			current_major=$(echo "$docker_version" | cut -d. -f1)
			minor=$(echo "$docker_version" | cut -d. -f2)
			local min_major min_minor
			min_major=$(echo "$min_version" | cut -d. -f1)
			min_minor=$(echo "$min_version" | cut -d. -f2)
			if ((current_major < min_major || (current_major == min_major && minor < min_minor))); then
				log "WARN: Docker version $docker_version is older than recommended minimum ($min_version+)"
			fi
		fi
	fi

	if ! command -v sops >/dev/null 2>&1; then
		log "FAIL: sops not installed"
		ok=false
	else
		local sops_version
		sops_version=$(sops --version 2>&1 | head -1)
		log "OK: sops ${sops_version} (Latest: v3.12.1)"
	fi

	if ! command -v jq >/dev/null 2>&1; then
		log "FAIL: jq not installed"
		ok=false
	else
		log "OK: jq available"
	fi

	if ! security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
		log "FAIL: AGE key not in Keychain"
		ok=false
	else
		log "OK: AGE key in Keychain"
	fi

	if [[ ! -f "$ENV_ENC" ]]; then
		log "WARN: .env.enc not found (run 'make encrypt')"
	else
		log "OK: .env.enc exists"
	fi

	if [[ -f ".sops.yaml" ]] && grep -q "$PLACEHOLDER_KEY" .sops.yaml; then
		log "FAIL: .sops.yaml has placeholder key (run 'make setup')"
		ok=false
	fi

	local config_file="${OPENCODE_CONFIG:-$DEFAULT_OPENCODE_CONFIG}"
	if [[ -f "$config_file" ]]; then
		# Strip JSONC comments before validating with jq
		local json_content
		json_content=$(grep -v '^[[:space:]]*//' "$config_file")
		if echo "$json_content" | jq -e . >/dev/null 2>&1; then
			log "OK: $config_file exists and is valid JSON"

			# Check if config has headers in options
			if ! echo "$json_content" | jq -e '.provider | to_entries[] | .value.options.headers.Authorization' >/dev/null 2>&1; then
				log "WARN: $config_file doesn't have Authorization headers (run 'make config' to regenerate)"
			fi
		else
			log "FAIL: $config_file exists but contains invalid JSON"
			ok=false
		fi
	else
		log "WARN: $config_file not found (run 'make config' to generate)"
	fi

	if "$ok"; then
		log "Validation passed"
	else
		log "Validation failed"
		return 1
	fi
}

cmd_clean() {
	log "Removing sandbox '${SANDBOX_NAME}'..."
	docker sandbox stop "$SANDBOX_NAME" 2>/dev/null || true
	docker sandbox rm "$SANDBOX_NAME" 2>/dev/null || true
	log "Sandbox removed"
	audit "clean" "sandbox removed"
}

cmd_models() {
	load_env || true
	local base_url="${OPENAI_COMPAT_BASE_URL:-}"
	local api_key="${OPENAI_COMPAT_API_KEY:-}"

	[[ -n "$base_url" ]] || err "OPENAI_COMPAT_BASE_URL not set. Set it in .env or environment."
	[[ -n "$api_key" ]] || err "OPENAI_COMPAT_API_KEY not set. Set it in .env or environment."
	command -v curl >/dev/null 2>&1 || err "curl not found."
	command -v jq >/dev/null 2>&1 || err "jq not found."

	# Validate URL scheme — require HTTPS unless targeting localhost/127.0.0.1
	local host
	host=$(echo "$base_url" | sed -E 's|^https?://([^/:]+).*|\1|')
	if [[ "$base_url" != https://* ]] && [[ "$host" != "localhost" ]] && [[ "$host" != 127.0.0.1 ]]; then
		err "OPENAI_COMPAT_BASE_URL must use HTTPS for non-local endpoints."
	fi

	local models_url="${base_url}${MODELS_ENDPOINT_PATH}"
	log "Fetching models from ${models_url}..."

	local response
	if ! response=$(curl -sS --fail --max-time "$MODELS_FETCH_TIMEOUT" \
		--max-filesize "$MAX_MODELS_RESPONSE_SIZE" \
		-H "Authorization: Bearer ${api_key}" \
		-H "Accept: application/json" \
		"$models_url" 2>&1); then
		err "Failed to fetch models: ${response}"
	fi

	# Validate response is JSON with a data array
	if ! echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
		err "Unexpected response format — expected {\"data\": [...]}"
	fi

	local model_count
	model_count=$(echo "$response" | jq '.data | length')
	log "Found ${model_count} models:"
	echo ""

	# Display models in a readable table
	echo "$response" | jq -r '.data[] | "  \(.id)\t\(.owned_by // "unknown")"' | sort | column -t -s $'\t'
	echo ""
	log "Run 'make config' to generate opencode.jsonc from these models."
	audit "models" "fetched ${model_count} models from ${base_url}"
}

cmd_config() {
	load_env || true
	local base_url="${OPENAI_COMPAT_BASE_URL:-}"
	local api_key="${OPENAI_COMPAT_API_KEY:-}"
	local provider_name="${OPENAI_COMPAT_PROVIDER_NAME:-$DEFAULT_PROVIDER_NAME}"
	local config_file="${OPENCODE_CONFIG:-$DEFAULT_OPENCODE_CONFIG}"

	[[ -n "$base_url" ]] || err "OPENAI_COMPAT_BASE_URL not set. Set it in .env or environment."
	[[ -n "$api_key" ]] || err "OPENAI_COMPAT_API_KEY not set. Set it in .env or environment."
	command -v curl >/dev/null 2>&1 || err "curl not found."
	command -v jq >/dev/null 2>&1 || err "jq not found."

	# Validate URL scheme
	local host
	host=$(echo "$base_url" | sed -E 's|^https?://([^/:]+).*|\1|')
	if [[ "$base_url" != https://* ]] && [[ "$host" != "localhost" ]] && [[ "$host" != 127.0.0.1 ]]; then
		err "OPENAI_COMPAT_BASE_URL must use HTTPS for non-local endpoints."
	fi

	local models_url="${base_url}${MODELS_ENDPOINT_PATH}"
	log "Fetching models from ${models_url}..."

	local response
	if ! response=$(curl -sS --fail --max-time "$MODELS_FETCH_TIMEOUT" \
		--max-filesize "$MAX_MODELS_RESPONSE_SIZE" \
		-H "Authorization: Bearer ${api_key}" \
		-H "Accept: application/json" \
		"$models_url" 2>&1); then
		err "Failed to fetch models: ${response}"
	fi

	if ! echo "$response" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
		err "Unexpected response format — expected {\"data\": [...]}"
	fi

	local model_count
	model_count=$(echo "$response" | jq '.data | length')

	if [[ "$model_count" -eq 0 ]]; then
		err "No models found at ${models_url}"
	fi

	log "Discovered ${model_count} models. Generating ${config_file}..."

	# Build the models object from the API response
	# Include context/output limits when available from the API response
	local models_json
	models_json=$(echo "$response" | jq '[.data[] | {
        key: .id,
        value: ({
            name: (.id | gsub("[_-]"; " ") | gsub("(?<a>\\b\\w)"; .a | ascii_upcase))
        } + (if .context_length then
            { limit: ({ context: .context_length }
                + (if .max_output_tokens then { output: .max_output_tokens } else {} end))
            }
        elif .max_model_len then
            { limit: { context: .max_model_len } }
        else {} end))
    }] | from_entries')

	# Pick the default model: prefer DEFAULT_MODEL_ID if available, else first model
	# Pick smallest-context model as small_model
	local default_model small_model
	# Check if preferred default model exists in discovered models
	if echo "$response" | jq -e --arg preferred "$DEFAULT_MODEL_ID" '.data[] | select(.id == $preferred)' >/dev/null 2>&1; then
		default_model="$DEFAULT_MODEL_ID"
		log "Using preferred default model: ${default_model}"
	else
		default_model=$(echo "$response" | jq -r '.data[0].id')
		log "Preferred model (${DEFAULT_MODEL_ID}) not found, using first model: ${default_model}"
	fi
	small_model=$(echo "$response" | jq -r '
        [.data[] | select(.context_length or .max_model_len)] |
        if length > 0 then
            sort_by(.context_length // .max_model_len // 999999)[0].id
        else empty end // empty')

	# Sanitize provider name for use as JSON key (alphanumeric, hyphens, underscores only)
	# Convert to lowercase for OpenCode compatibility
	provider_name=$(echo "$provider_name" | tr '[:upper:]' '[:lower:]' | tr -dc '[:alnum:]-_' | head -c 50)
	[[ -n "$provider_name" ]] || provider_name="$DEFAULT_PROVIDER_NAME"

	# Determine which env var to reference for the API key
	local api_key_env="OPENAI_COMPAT_API_KEY"

	# Generate the opencode.jsonc config
	# Use jq to build valid JSON; include small_model when auto-detected
	local config_json
	config_json=$(jq -n \
		--arg schema "https://opencode.ai/config.json" \
		--arg model "${provider_name}/${default_model}" \
		--arg small_model "${small_model:+${provider_name}/${small_model}}" \
		--arg provider_name "$provider_name" \
		--arg display_name "$provider_name" \
		--arg base_url "$base_url" \
		--arg api_key_ref "{env:${api_key_env}}" \
		--argjson models "$models_json" \
		'{
            "$schema": $schema,
            model: $model
        }
        + (if $small_model != "" and $small_model != $model
           then { small_model: $small_model } else {} end)
        + {
            enabled_providers: [$provider_name],
            provider: {
                ($provider_name): {
                    npm: "@ai-sdk/openai-compatible",
                    name: $display_name,
                    options: {
                        baseURL: $base_url,
                        apiKey: $api_key_ref,
                        headers: {
                            "Authorization": "Bearer " + $api_key_ref
                        }
                    },
                    models: $models
                }
            }
        }')

	# Write as plain JSON (not JSONC) for maximum compatibility
	# OpenCode should support both but some tooling may not handle comments
	echo "$config_json" >"$config_file"

	# Also write as opencode.json for maximum compatibility
	local json_file="${config_file%.jsonc}.json"
	if [[ "$config_file" != "$json_file" ]]; then
		echo "$config_json" >"$json_file"
		log "Generated ${config_file} and ${json_file} with ${model_count} models (default: ${provider_name}/${default_model})"
	else
		log "Generated ${config_file} with ${model_count} models (default: ${provider_name}/${default_model})"
	fi
	log "To use a different default model, edit the \"model\" field in ${config_file}"
	audit "config" "generated ${config_file} with ${model_count} models"
}

cmd_quickstart() {
	log "=== Agent Sandbox Quickstart ==="
	echo ""

	# Step 1: Validate .env exists and has required settings
	if [[ ! -f "$ENV_FILE" ]]; then
		if [[ -f ".env.example" ]]; then
			err "${ENV_FILE} not found. Copy .env.example and fill in your settings:\n  cp .env.example .env && vim .env"
		else
			err "${ENV_FILE} not found. Create it with your OPENAI_COMPAT_* settings."
		fi
	fi

	load_env || err "Failed to load ${ENV_FILE}"

	# Validate required vars are present
	[[ -n "${OPENAI_COMPAT_BASE_URL:-}" ]] || err "OPENAI_COMPAT_BASE_URL not set in ${ENV_FILE}"
	[[ -n "${OPENAI_COMPAT_API_KEY:-}" ]] || err "OPENAI_COMPAT_API_KEY not set in ${ENV_FILE}"

	log "Step 1/4: Settings validated"
	log "  Provider URL: ${OPENAI_COMPAT_BASE_URL}"
	log "  Provider name: ${OPENAI_COMPAT_PROVIDER_NAME:-$DEFAULT_PROVIDER_NAME}"
	echo ""

	# Step 2: Discover models
	log "Step 2/4: Discovering models..."
	cmd_models
	echo ""

	# Step 3: Generate config
	log "Step 3/4: Generating opencode.jsonc..."
	cmd_config
	echo ""

	# Step 4: Encrypt .env (if .sops.yaml exists with a real key)
	if [[ -f ".sops.yaml" ]] && ! grep -q "$PLACEHOLDER_KEY" .sops.yaml; then
		log "Step 4/4: Encrypting .env..."
		cmd_encrypt
	else
		log "Step 4/4: Skipping encryption (.sops.yaml not configured — run 'make setup' first)"
		log "  Your .env file still contains plaintext secrets"
	fi

	echo ""
	log "=== Quickstart complete ==="
	log "Next: make run REPO=~/your-project"
	audit "quickstart" "completed"
}

# --- Main ---

case "${1:-help}" in
setup) cmd_setup ;;
run) cmd_run "${2:-}" ;;
validate) cmd_validate ;;
clean) cmd_clean ;;
encrypt) cmd_encrypt ;;
decrypt) cmd_decrypt ;;
models) cmd_models ;;
config) cmd_config ;;
quickstart) cmd_quickstart ;;
version | --version | -V)
	_vfile="$(dirname "$0")/VERSION"
	if [[ -f "$_vfile" ]]; then
		echo "agent-sandbox $(tr -d '[:space:]' <"$_vfile")"
	else
		echo "agent-sandbox (version unknown)"
	fi
	;;
help | --help | -h)
	echo "Usage: $0 {quickstart|setup|run [repo_path]|validate|clean|encrypt|decrypt|models|config|version|help}"
	echo ""
	echo "Commands:"
	echo "  quickstart  Validate .env, discover models, generate config, encrypt (all-in-one)"
	echo "  setup       Install prerequisites, generate AGE key, create .sops.yaml"
	echo "  run         Launch OpenCode in a Docker sandbox with encrypted secrets"
	echo "  validate    Check all prerequisites are configured"
	echo "  clean       Stop and remove the sandbox"
	echo "  encrypt     Encrypt .env → .env.enc (removes plaintext)"
	echo "  decrypt     Decrypt .env.enc → .env (for editing)"
	echo "  models      List available models from OpenAI-compatible API"
	echo "  config      Generate opencode.jsonc from discovered models"
	echo "  version     Print version"
	echo "  help        Show this help message"
	;;
*) err "Unknown command: $1. Run '$0 help' for usage." ;;
esac
