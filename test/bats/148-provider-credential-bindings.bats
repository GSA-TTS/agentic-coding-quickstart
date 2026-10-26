#!/usr/bin/env bats
#
# 148-provider-credential-bindings.bats — acq-owned provider credential bindings
# and generic (non-USAi) provider credential injection.
#
# A provider kit is data: validated facts.json names its providerId, keyEnv,
# host, modelsUrl, and apiProtocol. acq owns the providerId -> (KEY_ENV, host)
# registry so a provider kit hosted outside the pinned Patterns release
# (`--kit git+https://…`) validates and is injected with no per-provider code —
# while a kit that merely CLAIMS an existing providerId cannot redirect a stored
# credential to a host the user never pinned.
#
# shellcheck shell=bats

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

# _make_generation PROVIDER KEY_ENV [HOST] — build a materialized generation
# directory holding one provider's validated facts.json, and echo its path.
_make_generation() {
  local provider_id="$1" key_env="$2" host="${3:-$1.example.gov}"
  local generation="$STUBDIR/generation.$provider_id"
  mkdir -p "$generation/models/providers/$provider_id"
  printf '{"schemaVersion":"acq-provider-facts/v1","providerId":"%s","apiProtocol":"openai-compatible","host":"%s","baseUrl":"https://%s/v1","modelsUrl":"https://%s/v1/models","keyEnv":"%s"}\n' \
    "$provider_id" "$host" "$host" "$host" "$key_env" \
    > "$generation/models/providers/$provider_id/facts.json"
  printf '%s\n' "$generation"
}

# _pin PROVIDER KEY_ENV HOST — write a registry entry straight into config.yaml.
_pin() {
  _acq_config_write_field provider_credential_bindings "$1=$2@$3"
}

# _provider_release ROOT — a stand-in pinned Patterns release: a validator stub
# that records the argv it received, and a base credential-bindings table.
_provider_release() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/integrations/isolation/schemas"
  cat > "$root/provider-python" <<'PYTHON'
#!/bin/sh
if [ "$1" = -c ]; then exit 0; fi
exec /usr/bin/python3 "$@"
PYTHON
  chmod +x "$root/provider-python"
  export ACQ_PROVIDER_INPUT_PYTHON="$root/provider-python"
  printf '{"providers":{"alpha":"ALPHA_KEY","beta":"BETA_KEY"}}\n' \
    > "$root/integrations/isolation/schemas/provider-credential-bindings.json"
  cat > "$root/scripts/validate_provider_input_contract.py" <<'PY'
import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['VALIDATOR_LOG']).write_text('\n'.join(args))
bindings = [args[i + 1] for i, value in enumerate(args) if value == '--credential-bindings'][0]
pathlib.Path(os.environ['VALIDATOR_BINDINGS_PATH']).write_text(bindings)
pathlib.Path(os.environ['VALIDATOR_BINDINGS_COPY']).write_text(
    pathlib.Path(bindings).read_text()
)
for bundle_path in [args[i + 1] for i, value in enumerate(args) if value == '--bundle']:
    json.loads(pathlib.Path(bundle_path).read_text())
PY
}

# _provider_kit ROOT NAME PROVIDER_ID KEY_ENV — a provider-role kit fixture.
_provider_kit() {
  local release="$1" name="$2" provider_id="${3:-$2}" key_env="$4"
  local kit="$release/integrations/isolation/acq-kits/$name"
  mkdir -p "$kit/provider-input" "$kit/scripts" "$kit/files"
  printf '{"providerId":"%s","schemaVersion":"acq-provider-input-bundle/v2","providerPath":"models/providers/%s","factsPath":"provider-input/facts.json","normalizerPath":"scripts/normalize","snapshotPath":"files/snapshot.json","credentialEnvNames":["%s"]}\n' \
    "$provider_id" "$provider_id" "$key_env" > "$kit/provider-input.json"
  printf '{"providerId":"%s"}\n' "$provider_id" > "$kit/provider-input/facts.json"
  printf '#!/bin/sh\n' > "$kit/scripts/normalize"; chmod 755 "$kit/scripts/normalize"
  printf '{"providerId":"%s","models":[]}\n' "$provider_id" > "$kit/files/snapshot.json"
  printf 'caps:\n  network:\n    allow:\n      - %s.example.gov\n' "$provider_id" > "$kit/spec.yaml"
}

# ---------------------------------------------------------------------------
# acq provider-credential set | ls | rm
# ---------------------------------------------------------------------------

@test "provider-credential set pins a provider to a host that ls reports" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY \
    --host models.opencode-go.example
  assert_success
  grep -Fq 'provider_credential_bindings: opencode-go=OPENCODE_GO_API_KEY@models.opencode-go.example' \
    "$XDG_CONFIG_HOME/acq/config.yaml"

  run "$ACQ" provider-credential ls
  assert_success
  assert_output --partial 'opencode-go'
  assert_output --partial 'OPENCODE_GO_API_KEY'
  assert_output --partial 'models.opencode-go.example'
  assert_output --partial 'config.yaml'
}

@test "provider-credential set REQUIRES an explicit host" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY
  assert_failure
  assert_output --partial 'a --host is required'
  assert_output --partial 'never infers it from a kit'
  refute [ -e "$XDG_CONFIG_HOME/acq/config.yaml" ]
}

@test "provider-credential set rejects a host that is not a bare DNS name" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY \
    --host 'https://models.opencode-go.example/v1'
  assert_failure
  assert_output --partial 'invalid host'

  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY \
    --host '*.opencode-go.example'
  assert_failure
  assert_output --partial 'invalid host'
}

@test "provider-credential set replaces one binding without dropping the others" {
  run "$ACQ" provider-credential set alpha ALPHA_KEY --host alpha.example.gov
  assert_success
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY \
    --host models.opencode-go.example
  assert_success
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_KEY_V2 \
    --host models2.opencode-go.example
  assert_success

  run "$ACQ" provider-credential ls
  assert_success
  assert_line --partial 'alpha'
  assert_line --partial 'ALPHA_KEY'
  refute_output --partial 'OPENCODE_GO_API_KEY'
  assert_line --partial 'OPENCODE_GO_KEY_V2'
  assert_line --partial 'models2.opencode-go.example'
}

@test "provider-credential set rejects a malformed provider id or KEY_ENV" {
  run "$ACQ" provider-credential set OpenCode OPENCODE_GO_API_KEY --host a.example.gov
  assert_failure
  assert_output --partial "invalid provider id 'OpenCode'"

  run "$ACQ" provider-credential set opencode-go opencode_go_key --host a.example.gov
  assert_failure
  assert_output --partial "invalid KEY_ENV 'opencode_go_key'"

  run "$ACQ" provider-credential set opencode- OPENCODE_GO_API_KEY --host a.example.gov
  assert_failure
  assert_output --partial 'invalid provider id'
}

@test "provider-credential set refuses reserved and process-critical KEY_ENVs" {
  run "$ACQ" provider-credential set opencode-go GITHUB_TOKEN --host a.example.gov
  assert_failure
  assert_output --partial "belongs to the 'github' service"

  run "$ACQ" provider-credential set opencode-go PATH --host a.example.gov
  assert_failure
  assert_output --partial 'invalid KEY_ENV'

  # The owning provider may still use its own name (nothing to pin, but valid).
  run "$ACQ" provider-credential set github GITHUB_TOKEN --host github.com
  assert_success
}

@test "provider-credential set rejects an unexpected extra argument" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY \
    --host a.example.gov --bogus
  assert_failure
  assert_output --partial "unexpected argument '--bogus'"
}

@test "provider-credential rm removes a binding and reports an unknown one" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY --host a.example.gov
  assert_success

  run "$ACQ" provider-credential rm opencode-go
  assert_success
  run "$ACQ" provider-credential ls
  assert_success
  assert_output --partial '(none)'

  run "$ACQ" provider-credential rm opencode-go
  assert_failure
  assert_output --partial "no config.yaml binding for provider 'opencode-go'"
}

@test "provider-credential ls prints both layers on separate lines" {
  run "$ACQ" provider-credential set alpha ALPHA_KEY --host a.example.gov
  assert_success
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='beta=BETA_KEY@b.example.gov'

  run "$ACQ" provider-credential ls
  assert_success
  # One row per layer — the config row must not be glued onto the env row.
  assert_line --partial 'alpha'
  assert_line --partial 'config.yaml'
  assert_line --partial 'beta'
  assert_line --partial 'env'
  [ "${#lines[@]}" -ge 3 ]
  printf '%s\n' "${lines[@]}" | grep -q 'config.yaml$'
}

@test "provider-credential ls fails closed on a malformed env layer" {
  run env ACQ_PROVIDER_CREDENTIAL_BINDINGS='not-a-pair' \
    "$ACQ" provider-credential ls
  assert_failure
  assert_output --partial "expected '<providerId>=<KEY_ENV>'"
}

@test "provider-credential with no subcommand prints usage and is a usage error" {
  run "$ACQ" provider-credential
  assert_failure 2
  assert_output --partial 'acq provider-credential'

  run "$ACQ" provider-credential --help
  assert_success
  assert_output --partial 'ACQ_PROVIDER_CREDENTIAL_BINDINGS'
  assert_output --partial '--host is REQUIRED'
}

# ---------------------------------------------------------------------------
# Three-layer merge into the pinned validator
# ---------------------------------------------------------------------------

@test "prepare validates against the merged registry (base + config + env)" {
  local release="$STUBDIR/release" bindings_path
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  # shellcheck disable=SC2034 # acq_provider_input_prepare reads this global
  KITS=("$release/integrations/isolation/acq-kits/alpha")

  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='beta=BETA_KEY_FROM_ENV@b.example.gov'
  run "$ACQ" provider-credential set gamma GAMMA_KEY --host g.example.gov
  assert_success

  run acq_provider_input_prepare sbx mergebox
  assert_success

  # The validator saw a MERGED file, not the pinned base file.
  bindings_path=$(cat "$VALIDATOR_BINDINGS_PATH")
  [ "$bindings_path" != \
    "$release/integrations/isolation/schemas/provider-credential-bindings.json" ]
  # Base defaults survive; config and env layers are layered on top. The document
  # keeps the validator's own shape (providerId -> ENV), so acq's host pins never
  # leak into the schema the pinned release defines.
  grep -Fq '"alpha": "ALPHA_KEY"' "$VALIDATOR_BINDINGS_COPY"
  grep -Fq '"beta": "BETA_KEY_FROM_ENV"' "$VALIDATOR_BINDINGS_COPY"
  grep -Fq '"gamma": "GAMMA_KEY"' "$VALIDATOR_BINDINGS_COPY"
  refute grep -Fq '"hosts"' "$VALIDATOR_BINDINGS_COPY"
  # The merged file lived in the staging dir, so the stage cleanup removed it.
  refute [ -e "$bindings_path" ]
}

@test "prepare fails closed on a malformed registry entry and never validates" {
  local release="$STUBDIR/release" root
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  # shellcheck disable=SC2034 # acq_provider_input_prepare reads this global
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='broken-token'

  run acq_provider_input_prepare sbx badbindings
  assert_failure
  assert_output --partial "expected '<providerId>=<KEY_ENV>'"
  refute [ -e "$STUBDIR/validator.log" ]

  root=$(acq_provider_input_root sbx badbindings)
  refute [ -e "$root/current" ]
}

@test "prepare fails closed when a provider id in the registry is unsafe" {
  local release="$STUBDIR/release"
  _provider_release "$release"
  _provider_kit "$release" alpha alpha ALPHA_KEY
  export VALIDATOR_LOG="$STUBDIR/validator.log"
  export VALIDATOR_BINDINGS_PATH="$STUBDIR/bindings-path"
  export VALIDATOR_BINDINGS_COPY="$STUBDIR/bindings-copy.json"
  _acq_provider_input_control_plane() { printf '%s\n' "$release"; }
  # shellcheck disable=SC2034 # acq_provider_input_prepare reads this global
  KITS=("$release/integrations/isolation/acq-kits/alpha")
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='bad/id=BAD_KEY'

  run acq_provider_input_prepare sbx badidbox
  assert_failure
  assert_output --partial 'invalid provider id'
  refute [ -e "$STUBDIR/validator.log" ]
}

# ---------------------------------------------------------------------------
# Registry drives generic provider handling
# ---------------------------------------------------------------------------

@test "a registry provider is an acq-managed service with an importable key env" {
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='opencode-go=OPENCODE_GO_API_KEY@go.example.gov'

  run _acq_is_managed_service opencode-go
  assert_success

  run _acq_import_env_vars_for opencode-go
  assert_success
  assert_output 'OPENCODE_GO_API_KEY'

  run _acq_is_managed_service not-a-registry-provider
  assert_failure

  # `acq secret rm <providerId>` routes to the acq-store removal path.
  run _acq_is_managed_secret_rm -g opencode-go
  assert_success
}

@test "secret import needs --service for a provider id so it cannot become a scope" {
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='opencode-go=OPENCODE_GO_API_KEY@go.example.gov'

  # A bare provider id is treated as the SANDBOX scope (refresh semantics kept),
  # never as a service.
  run _acq_import_parse_args opencode-go
  assert_success
  assert_output "$(printf 'interactive\t0\t\topencode-go')"

  run _acq_import_parse_args --service=opencode-go
  assert_success
  assert_output "$(printf 'interactive\t0\topencode-go\t')"

  run _acq_import_parse_args --service=nope-not-a-provider
  assert_failure
  assert_output --partial 'unknown service'
}

@test "the env layer overrides the config layer for one provider" {
  run "$ACQ" provider-credential set opencode-go OPENCODE_GO_API_KEY --host a.example.gov
  assert_success
  export ACQ_PROVIDER_CREDENTIAL_BINDINGS='opencode-go=OPENCODE_GO_OVERRIDE@b.example.gov'

  run acq_provider_credential_key_env opencode-go
  assert_success
  assert_output 'OPENCODE_GO_OVERRIDE'

  run acq_provider_credential_hosts opencode-go
  assert_success
  assert_output 'b.example.gov'
}

@test "configure shows the configured provider bindings" {
  _acq_config_write_field provider_credential_bindings 'opencode-go=OPENCODE_GO_API_KEY@go.example.gov'

  run _acq_configure_show_current
  assert_success
  assert_output --partial 'provider creds:     opencode-go=OPENCODE_GO_API_KEY@go.example.gov'
}

# ---------------------------------------------------------------------------
# facts.json is the only provider-specific input, and it is untrusted
# ---------------------------------------------------------------------------

@test "facts.json records are validated before they become backend arguments" {
  local generation record expected
  generation=$(_make_generation opencode-go OPENCODE_GO_API_KEY)
  record="$generation/models/providers/opencode-go/facts.json"

  run acq_provider_facts_json_fields "$record"
  assert_success
  expected=$(printf 'opencode-go\tOPENCODE_GO_API_KEY\topencode-go.example.gov\thttps://opencode-go.example.gov/v1/models\topenai-compatible')
  assert_output "$expected"
}

@test "facts.json with an unsafe keyEnv or a non-https models URL is rejected" {
  local generation record
  generation=$(_make_generation alpha ALPHA_KEY)
  record="$generation/models/providers/alpha/facts.json"

  printf '{"providerId":"alpha","keyEnv":"KEY; rm -rf /","host":"alpha.example.gov","modelsUrl":"https://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure

  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"http://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure

  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov/v1","modelsUrl":"https://alpha.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure
}

@test "facts.json whose modelsUrl names a different host is rejected" {
  local generation record
  generation=$(_make_generation alpha ALPHA_KEY)
  record="$generation/models/providers/alpha/facts.json"

  # Credential would be sent to alpha.example.gov while the probe (and so the
  # validation) pointed at attacker.example.gov.
  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"https://attacker.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure
}

@test "facts.json with shell punctuation in modelsUrl is rejected" {
  local generation record
  generation=$(_make_generation alpha ALPHA_KEY)
  record="$generation/models/providers/alpha/facts.json"

  # `&` would start a second command if the URL were ever spliced into a program.
  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"https://alpha.example.gov/v1/models?a=1&b=2","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure

  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"https://alpha.example.gov/v1/models;id","apiProtocol":"openai-compatible"}\n' \
    > "$record"
  run acq_provider_facts_json_fields "$record"
  assert_failure
}

@test "facts are read with the resolved runtime, and their absence fails closed" {
  local generation record wrapper="$STUBDIR/facts-python"
  generation=$(_make_generation alpha ALPHA_KEY)
  record="$generation/models/providers/alpha/facts.json"

  cat > "$wrapper" <<'PYTHON'
#!/bin/sh
exec /usr/bin/python3 "$@"
PYTHON
  chmod +x "$wrapper"

  ACQ_PROVIDER_INPUT_PYTHON="$wrapper"
  export ACQ_PROVIDER_INPUT_PYTHON
  run acq_provider_facts_json_fields "$record"
  assert_success

  # No resolved runtime and no python3 reachable: refuse, never "no providers".
  # (The prefix assignment above persists for function calls, so unset it here,
  # and point every runtime location at an empty scratch dir.)
  unset ACQ_PROVIDER_INPUT_PYTHON
  rm -f "$wrapper"
  local saved_path="$PATH" saved_localappdata="${LOCALAPPDATA:-}"
  mkdir -p "$STUBDIR/emptybin"
  PATH="$STUBDIR/emptybin"
  LOCALAPPDATA="$STUBDIR/no-localappdata"
  ACQ_PROVIDER_INPUT_DATA_DIR="$STUBDIR/no-runtime"
  export PATH LOCALAPPDATA ACQ_PROVIDER_INPUT_DATA_DIR
  hash -r 2>/dev/null || true
  run acq_provider_facts_json_fields "$record"
  PATH="$saved_path"
  LOCALAPPDATA="$saved_localappdata"
  export PATH LOCALAPPDATA
  unset ACQ_PROVIDER_INPUT_DATA_DIR
  hash -r 2>/dev/null || true
  assert_failure
  assert_output --partial 'no Python runtime available to read provider facts'
}

@test "a missing facts.json is not an error, it is simply no provider facts" {
  run acq_provider_facts_json_fields "$STUBDIR/absent/facts.json"
  assert_failure 1
  run acq_provider_facts_list_generation "$STUBDIR/absent-generation"
  assert_success
  assert_output ''
}

@test "an invalid facts.json in a generation fails closed instead of being skipped" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  printf '{"providerId":"alpha","keyEnv":"ALPHA_KEY","host":"alpha.example.gov","modelsUrl":"https://attacker.example.gov/v1/models","apiProtocol":"openai-compatible"}\n' \
    > "$generation/models/providers/alpha/facts.json"

  run acq_provider_facts_list_generation "$generation"
  assert_failure
  assert_output --partial 'invalid provider facts'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial 'invalid provider facts'
  # Nothing was recorded for a generation that failed validation.
  run acq_host_config_read msb box provider-credentials
  assert_output ''
}

# ---------------------------------------------------------------------------
# Host pinning: the anti-spoofing control
# ---------------------------------------------------------------------------

@test "credentials gate rejects a kit whose host is not the pinned host" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY attacker.example.gov)
  _pin alpha ALPHA_KEY alpha.example.gov
  export ALPHA_KEY='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial "not one of"
  assert_output --partial 'Refusing to send the stored credential there'
}

@test "credentials gate rejects an unpinned provider instead of trusting the kit" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  export ALPHA_KEY='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial 'is not pinned to a host yet'
  assert_output --partial 'acq provider-credential set alpha <KEY_ENV> --host alpha.example.gov'
}

@test "credentials gate refuses a host change against the recorded host" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY attacker.example.gov)
  acq_host_config_write msb box provider-credentials \
    "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai-compatible')"
  export ALPHA_KEY='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial 'host changed for sandbox'
  assert_output --partial 'Refusing to silently move your credential'
}

@test "credentials gate accepts the recorded host on a re-run" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  acq_host_config_write msb box provider-credentials \
    "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai-compatible')"
  export ALPHA_KEY='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_success
}

@test "credentials gate refuses a provider id that shadows an sbx built-in" {
  local generation
  generation=$(_make_generation openai OPENAI_API_KEY)
  _pin openai OPENAI_API_KEY openai.example.gov
  export OPENAI_API_KEY='exported-by-ci'

  run acq_provider_credentials_gate sbx box "$generation"
  assert_failure
  assert_output --partial "collides with an sbx built-in service"
}

@test "credentials gate gates gitlab instead of skipping it" {
  local generation
  # `gitlab` is an acq-managed secret but NOT hard-coded by either backend's
  # binding layer, so a kit claiming it must still pass the host-pin check.
  generation=$(_make_generation gitlab GITLAB_TOKEN attacker.example.gov)
  _pin gitlab GITLAB_TOKEN gitlab.com
  export GITLAB_TOKEN='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial 'Refusing to send the stored credential there'
}

@test "credentials gate refuses an unpinned gitlab provider" {
  local generation
  generation=$(_make_generation gitlab GITLAB_TOKEN attacker.example.gov)
  export GITLAB_TOKEN='exported-by-ci'

  run acq_provider_credentials_gate msb box "$generation"
  assert_failure
  assert_output --partial 'is not pinned to a host yet'
}

@test "credentials gate still skips the ids both backends hard-code" {
  local generation
  generation=$(_make_generation github GITHUB_TOKEN)
  mkdir -p "$generation/models/providers/usai"
  printf '{"providerId":"usai","apiProtocol":"openai-compatible","host":"api.gsa.usai.gov","modelsUrl":"https://api.gsa.usai.gov/api/v1/models","keyEnv":"USAI_API_KEY"}\n' \
    > "$generation/models/providers/usai/facts.json"

  run acq_provider_credentials_gate msb box "$generation"
  assert_success
}

@test "a tampered provider-credentials record is rejected, not parsed" {
  acq_host_config_write msb box provider-credentials \
    "$(printf 'alpha\tEVIL;touch /tmp/pwned\thttp://x\tnope\tprotocol')"

  run acq_provider_recorded_facts msb box
  assert_failure
  assert_output --partial 'invalid provider-credentials record'

  # …and the binding path fails closed instead of falling back to a pin.
  export ACQ_RESOLVED_BACKEND=msb
  _pin alpha ALPHA_KEY alpha.example.gov
  run acq_provider_binding_host_env alpha box
  assert_failure
}

@test "a multi-host pin binds every pinned host" {
  _acq_config_write_field provider_credential_bindings \
    'alpha=ALPHA_KEY@a.example.gov,b.example.gov'

  run acq_provider_binding sbx "" alpha
  assert_success
  assert_output --partial 'a.example.gov,b.example.gov'
}

@test "check_provider_key refuses a cross-host models URL at the probe" {
  acq_provider_binding() { printf '%s\t%s\t%s\n' alpha.example.gov ALPHA_KEY https://attacker.example.gov/v1/models; }
  acq_backend_run() { printf '200|0\n'; }

  run check_provider_key probe-box alpha
  assert_failure
  assert_output --partial 'models URL does not match its declared host'
}

@test "check_provider_key refuses an unsafe credential env name" {
  acq_provider_binding() { printf '%s\t%s\t%s\n' alpha.example.gov 'EVIL;touch x' https://alpha.example.gov/v1/models; }

  run check_provider_key probe-box alpha
  assert_failure
  assert_output --partial 'unsafe credential env name'
}

# ---------------------------------------------------------------------------
# Create-time gate behaviour
# ---------------------------------------------------------------------------

@test "credentials gate records provider facts and never gates usai" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  mkdir -p "$generation/models/providers/usai"
  printf '{"providerId":"usai","apiProtocol":"openai-compatible","host":"api.gsa.usai.gov","modelsUrl":"https://api.gsa.usai.gov/api/v1/models","keyEnv":"USAI_API_KEY"}\n' \
    > "$generation/models/providers/usai/facts.json"
  _pin alpha ALPHA_KEY alpha.example.gov
  export ALPHA_KEY='exported-by-ci'

  # USAI_API_KEY is deliberately unset: USAi keeps its own pre-create gate.
  run acq_provider_credentials_gate msb credbox "$generation"
  assert_success
  refute_output --partial 'USAI_API_KEY'

  run acq_host_config_read msb credbox provider-credentials
  assert_success
  assert_output --partial 'alpha'
}

@test "credentials gate fails closed non-interactively when a provider key is missing" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  _pin alpha ALPHA_KEY alpha.example.gov

  run acq_provider_credentials_gate msb credbox "$generation"
  assert_failure
  assert_output --partial "no key stored for provider 'alpha' (\$ALPHA_KEY)"
  assert_output --partial 'acq secret set -g alpha'
}

@test "an exported key satisfies an msb gate but fails closed on sbx" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  _pin alpha ALPHA_KEY alpha.example.gov
  export ALPHA_KEY='exported-by-ci'

  run acq_provider_credentials_gate msb credbox "$generation"
  assert_success

  run acq_provider_credentials_gate sbx credbox "$generation"
  assert_failure
  assert_output --partial 'cannot bind a credential from host env at create'
  assert_output --partial 'acq secret set -g alpha'
}

@test "credentials gate is a no-op for a generation with no providers" {
  local generation="$STUBDIR/empty-generation"
  mkdir -p "$generation/models/providers"

  run acq_provider_credentials_gate msb credbox "$generation"
  assert_success
  run acq_host_config_read msb credbox provider-credentials
  assert_success
  assert_output ''
}

# ---------------------------------------------------------------------------
# Generic key validation + binding resolution
# ---------------------------------------------------------------------------

@test "check_provider_key passes the models URL as data, never as program text" {
  local generation probe script
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  probe="$STUBDIR/probe.sh"
  script="$STUBDIR/probe-program"
  acq_backend_run() {
    printf '%s\n' "$5" > "$script"
    printf '%s\n' "$7" > "$probe"
    printf '200|0\n'
  }

  run check_provider_key probe-box alpha
  assert_success
  assert_output '200'
  # The URL is argument 7 (data), and the program text only references "$1".
  assert_equal "$(cat "$probe")" 'https://alpha.example.gov/v1/models'
  grep -Fq 'Bearer $ALPHA_KEY' "$script"
  grep -Fq '"$1"' "$script"
  refute grep -Fq 'alpha.example.gov' "$script"
}

@test "check_provider_key reports an unauthorized provider key" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  acq_backend_run() { printf '401|0\n'; }

  run check_provider_key probe-box alpha
  assert_success
  assert_output '401'
}

@test "ensure_valid_provider_keys fails closed on a rejected provider key" {
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf '401\n'; }

  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial "provider 'alpha' rejected the stored key (HTTP 401)"
  assert_output --partial 'acq secret set -g alpha'
}

@test "ensure_valid_provider_keys fails closed on an inconclusive probe" {
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf '\n'; }

  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial 'could not validate the'
  assert_output --partial 'unverified credential'
}

@test "ensure_valid_provider_keys treats 5xx as transient and 3xx as a redirect" {
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf '503\n'; }

  run ensure_valid_provider_keys probe-box
  assert_success
  assert_output --partial 'transient'

  check_provider_key() { printf '302\n'; }
  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial 'redirected (HTTP 302)'
}

@test "ensure_valid_provider_keys treats an unreachable endpoint as a network problem" {
  acq_provider_sandbox_provider_ids() { printf 'alpha\n'; }
  check_provider_key() { printf 'unreachable\n'; }

  run ensure_valid_provider_keys probe-box
  assert_failure
  assert_output --partial 'That is a network problem, not a credential one.'
}

@test "ensure_valid_provider_keys skips usai" {
  acq_provider_sandbox_provider_ids() { printf 'usai\n'; }
  check_provider_key() { printf '401\n'; }

  run ensure_valid_provider_keys probe-box
  assert_success
  assert_output ''
}

@test "sbx maps a registry provider to its facts host and key env" {
  local generation expected
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"

  run _acq_service_hosts_env alpha
  assert_success
  expected=$(printf 'alpha.example.gov\tALPHA_KEY')
  assert_output "$expected"

  run _acq_service_hosts_env not-a-provider
  assert_success
  expected=$(printf '\t')
  assert_output "$expected"
}

@test "the registry keyEnv is authoritative for injection" {
  local generation binding
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  _pin alpha ALPHA_KEY_OVERRIDE alpha.example.gov

  run acq_provider_binding sbx box alpha
  assert_success
  assert_output --partial 'ALPHA_KEY_OVERRIDE'
}

@test "a pinned provider resolves host/keyEnv with no generation and no ambient state" {
  # This is the resume / `acq secret rm` path: an explicit sandbox argument, no
  # ACQ_PROVIDER_BINDINGS_* environment, and only the recorded host config.
  _pin alpha ALPHA_KEY alpha.example.gov
  acq_host_config_write msb livebox provider-credentials \
    "$(printf 'alpha\tALPHA_KEY\talpha.example.gov\thttps://alpha.example.gov/v1/models\topenai-compatible')"

  run acq_provider_binding_host_env alpha livebox
  assert_success
  assert_output "$(printf 'alpha.example.gov\tALPHA_KEY')"

  # A standalone global `acq secret set` (no sandbox) still resolves via the pin.
  run acq_provider_binding_host_env alpha
  assert_success
  assert_output "$(printf 'alpha.example.gov\tALPHA_KEY')"
}

@test "sbx reports a registry provider injectable only once its key env is bound" {
  local generation
  generation=$(_make_generation alpha ALPHA_KEY)
  export ACQ_PROVIDER_BINDINGS_GENERATION="$generation"
  _acq_sbx_secret_exists() { return 1; }

  run acq_backend_key_present alpha
  assert_failure

  _acq_sbx_secret_exists() { return 0; }
  run acq_backend_key_present alpha
  assert_success

  # Services acq does not model keep the documented permissive default.
  run acq_backend_key_present some-raw-placeholder
  assert_success
}
