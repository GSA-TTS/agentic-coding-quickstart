#!/usr/bin/env bats
#
# 149-kit-source.bats — the trusted kit-source registry, the fetch allowlist
# derived from it, provider-kit discovery, and `provider_kit:` as data.
#
# Trust is narrow on purpose: a trusted source may be FETCHED from and may
# contribute provider kits, but the validator/schemas stay pinned to the Patterns
# release (D1). Provider kits from trusted sources are AUTO-LISTED (D2), and the
# default provider kit is a config value rather than a constant (D3).
#
# shellcheck shell=bats

load 'helper'

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

# _fake_source_tree ROOT KIT... — a fetched source tree with provider kits, plus a
# stub kit_translate_fetch that "fetches" it, so discovery never touches network.
_fake_source_tree() {
  local root="$1"; shift
  local kit
  mkdir -p "$root"
  for kit in "$@"; do
    mkdir -p "$root/$kit"
    printf '{"providerId":"%s"}\n' "$kit" > "$root/$kit/provider-input.json"
  done
  mkdir -p "$root/not-a-provider-kit"
  printf 'schemaVersion: "hybrid/v1"\n' > "$root/not-a-provider-kit/spec.yaml"
  # Global, not a local of this helper: the stub outlives this call.
  _FAKE_SOURCE_ROOT="$root"
  kit_translate_fetch() {
    printf '%s\n' "$_FAKE_SOURCE_ROOT"
  }
}

# ---------------------------------------------------------------------------
# Registry: add / rm / ls
# ---------------------------------------------------------------------------

@test "kit-source: the shipped default is registered without any config" {
  run acq_kit_sources_entries
  assert_success
  assert_output --partial 'github.com/GSA-TTS/agentic-coding-patterns'
  assert_output --partial "$PATTERNS_KIT_REF"
  assert_output --partial 'integrations/isolation/acq-kits'
}

@test "kit-source add persists a pinned source that ls reports" {
  run "$ACQ" kit-source add github.com/mogul/agentic-coding-kits --ref deadbeef
  assert_success

  grep -Fq 'kit_sources:' "$XDG_CONFIG_HOME/acq/config.yaml"
  grep -Fq 'github.com/mogul/agentic-coding-kits@deadbeef' "$XDG_CONFIG_HOME/acq/config.yaml"

  run acq_kit_sources_entries
  assert_success
  # Adding a source keeps the shipped default: trust is additive.
  assert_output --partial 'github.com/GSA-TTS/agentic-coding-patterns'
  assert_output --partial 'github.com/mogul/agentic-coding-kits'
}

@test "kit-source add replaces an existing entry for the same repo" {
  run "$ACQ" kit-source add github.com/mogul/kits --ref aaaa
  assert_success
  run "$ACQ" kit-source add github.com/mogul/kits --ref bbbb
  assert_success
  assert_output --partial 'updated kit source'

  run acq_kit_sources_entries
  assert_success
  refute_output --partial '|aaaa|'
  assert_output --partial '|bbbb|'
}

@test "kit-source add requires a pinned ref" {
  run "$ACQ" kit-source add github.com/mogul/kits
  assert_failure
  assert_output --partial '--ref <sha> is required'
  refute [ -e "$XDG_CONFIG_HOME/acq/config.yaml" ]
}

@test "kit-source add normalizes a pasted clone URL" {
  run "$ACQ" kit-source add 'git+https://github.com/mogul/kits.git' --ref abcd1234
  assert_success
  run acq_kit_sources_entries
  assert_success
  assert_output --partial 'github.com/mogul/kits'
  refute_output --partial 'git+https'
}

@test "kit-source rejects a credential-bearing or malformed repository" {
  run "$ACQ" kit-source add 'https://token@github.com/mogul/kits' --ref abcd
  assert_failure
  assert_output --partial 'invalid repository'

  run "$ACQ" kit-source add 'not-a-repo' --ref abcd
  assert_failure
  assert_output --partial 'invalid repository'
}

@test "kit-source rm drops a source and 'none' means no trusted sources" {
  run "$ACQ" kit-source add github.com/mogul/kits --ref abcd
  assert_success

  run "$ACQ" kit-source rm github.com/mogul/kits
  assert_success
  run acq_kit_sources_entries
  assert_success
  refute_output --partial 'mogul'

  # Removing the shipped default leaves acq with NOTHING to fetch (the flat
  # writer would otherwise drop the key and resurrect the default).
  run "$ACQ" kit-source rm github.com/GSA-TTS/agentic-coding-patterns
  assert_success
  grep -Fq 'kit_sources: none' "$XDG_CONFIG_HOME/acq/config.yaml"
  run acq_kit_sources_entries
  assert_success
  assert_output ''
}

@test "kit-source rm reports an unregistered repository" {
  run "$ACQ" kit-source rm github.com/other/repo
  assert_failure
  assert_output --partial 'is not registered'
}

@test "kit-source with no subcommand prints usage and is a usage error" {
  run "$ACQ" kit-source
  assert_failure 2
  assert_output --partial 'acq kit-source'

  run "$ACQ" kit-source --help
  assert_success
  assert_output --partial 'ACQ_KIT_SOURCES'
}

# ---------------------------------------------------------------------------
# Allowlist derivation
# ---------------------------------------------------------------------------

@test "the fetch allowlist is derived from the registry" {
  run acq_kit_source_prefixes
  assert_success
  assert_output 'github.com/GSA-TTS/'

  run "$ACQ" kit-source add github.com/mogul/agentic-coding-kits --ref abcd
  assert_success
  run acq_kit_source_prefixes
  assert_success
  assert_line 'github.com/GSA-TTS/'
  assert_line 'github.com/mogul/'
}

@test "ACQ_EXTRA_KIT_SOURCES still adds prefixes (backward compatibility)" {
  export ACQ_EXTRA_KIT_SOURCES='github.com/legacy/'

  run acq_kit_source_prefixes
  assert_success
  assert_output --partial 'github.com/GSA-TTS/'
  assert_output --partial 'github.com/legacy/'
}

@test "_build_kit_list populates KIT_SOURCE_PREFIXES from the registry" {
  export ACQ_KIT_SOURCES='github.com/mogul/agentic-coding-kits@abcd'
  _build_kit_list

  printf '%s\n' "${KIT_SOURCE_PREFIXES[@]}" > "$STUBDIR/prefixes"
  grep -Fq 'github.com/mogul/' "$STUBDIR/prefixes"
  refute grep -Fq 'github.com/GSA-TTS/' "$STUBDIR/prefixes"
}

@test "ACQ_KIT_SOURCES overrides the configured sources for one invocation" {
  run "$ACQ" kit-source add github.com/config/kits --ref aaaa
  assert_success
  export ACQ_KIT_SOURCES='github.com/envonly/kits@bbbb'

  run acq_kit_sources_entries
  assert_success
  assert_output --partial 'github.com/envonly/kits'
  refute_output --partial 'github.com/config/kits'

  run "$ACQ" kit-source ls
  assert_success
  assert_output --partial 'github.com/envonly/kits'
}

# ---------------------------------------------------------------------------
# Provider-kit discovery (auto-list, D2)
# ---------------------------------------------------------------------------

@test "discovery lists only directories that ship provider-input.json" {
  local tree="$STUBDIR/source-tree"
  _fake_source_tree "$tree" alpha-provider beta-provider

  run acq_kit_source_provider_kits github.com/mogul/kits abcd integrations/isolation/acq-kits
  assert_success
  assert_output --partial 'alpha-provider'
  assert_output --partial 'beta-provider'
  refute_output --partial 'not-a-provider-kit'
}

@test "an unreachable source lists no kits and does not fail" {
  kit_translate_fetch() { return 1; }

  run acq_kit_source_provider_kits github.com/mogul/kits abcd integrations/isolation/acq-kits
  assert_success
  assert_output ''
}

@test "kit-source ls shows sources and the provider kits they publish" {
  local tree="$STUBDIR/source-tree"
  _fake_source_tree "$tree" alpha-provider beta-provider
  export ACQ_KIT_SOURCES='github.com/mogul/kits@abcd'

  # In-process: discovery shells out through kit_translate_fetch, which the test
  # stubs (a `$ACQ` child process would use the real network fetch).
  run acq_kit_source_ls
  assert_success
  assert_output --partial 'github.com/mogul/kits'
  assert_output --partial 'abcd'
  assert_output --partial 'alpha-provider'
  assert_output --partial 'beta-provider'
}

@test "provider-kit candidates include the shipped default and discovered kits" {
  local tree="$STUBDIR/source-tree"
  _fake_source_tree "$tree" opencode-go-provider
  export ACQ_KIT_SOURCES='github.com/mogul/kits@abcd'

  run acq_provider_kit_candidates
  assert_success
  assert_output --partial 'agentic-coding-patterns/usai-provider'
  assert_output --partial 'github.com/mogul/kits'
  assert_output --partial 'opencode-go-provider'
}

# ---------------------------------------------------------------------------
# provider_kit as data (D3)
# ---------------------------------------------------------------------------

@test "the default provider kit resolves to the pinned patterns kit ref" {
  run acq_provider_kit_ref
  assert_success

  assert_output "$USAI_KIT"
}

@test "provider_kit accepts <source>/<kit> and <kit>@<repo> forms" {
  run "$ACQ" kit-source add github.com/mogul/agentic-coding-kits --ref abcd
  assert_success

  _acq_config_write_field provider_kit 'agentic-coding-kits/opencode-go-provider'
  run acq_provider_kit_ref
  assert_success
  assert_output 'git+https://github.com/mogul/agentic-coding-kits.git#ref=abcd&dir=integrations/isolation/acq-kits/opencode-go-provider'

  _acq_config_write_field provider_kit 'opencode-go-provider@github.com/mogul/agentic-coding-kits'
  run acq_provider_kit_ref
  assert_success
  assert_output --partial 'github.com/mogul/agentic-coding-kits.git#ref=abcd'

  _acq_config_write_field provider_kit 'github.com/mogul/agentic-coding-kits/opencode-go-provider'
  run acq_provider_kit_ref
  assert_success
  assert_output --partial 'dir=integrations/isolation/acq-kits/opencode-go-provider'
}

@test "provider_kit fails closed for an untrusted source" {
  _acq_config_write_field provider_kit 'evil-kits/opencode-go-provider'

  run acq_provider_kit_ref
  assert_failure
  assert_output --partial "kit source name 'evil-kits' is not registered"
}

@test "provider_kit fails closed for a source with no pinned ref" {
  _acq_config_write_field kit_sources 'github.com/mogul/kits'
  _acq_config_write_field provider_kit 'kits/opencode-go-provider'

  run acq_provider_kit_ref
  assert_failure
  assert_output --partial 'has no pinned ref'
}

@test "the selected provider kit feeds the provider-input pipeline" {
  local tree="$STUBDIR/source-tree" refs
  _fake_source_tree "$tree" opencode-go-provider
  run "$ACQ" kit-source add github.com/mogul/kits --ref abcd
  assert_success
  _acq_config_write_field provider_kit 'kits/opencode-go-provider'

  refs=$(_acq_selected_provider_kit_refs)
  case "$refs" in
    *'github.com/mogul/kits.git#ref=abcd'*) ;;
    *) fail "provider kit ref not selected: $refs" ;;
  esac
  refute grep -Fq 'usai-provider' <<<"$refs"
}

# ---------------------------------------------------------------------------
# Regression guards from review
# ---------------------------------------------------------------------------

@test "secret import still accepts a bare usai token and --all scans it" {
  # usai is no longer a compiled-in managed service; it is reachable through the
  # trust anchor, so both the bare form and the full scan must keep working.
  run _acq_import_parse_args usai
  assert_success
  assert_output "$(printf 'interactive\t0\tusai\t')"

  run acq_importable_services
  assert_success
  assert_line 'usai'
  assert_line 'github'
  assert_line 'gitlab'
}

@test "adding a source does not freeze the shipped default ref" {
  run "$ACQ" kit-source add github.com/mogul/kits --ref abcd
  assert_success

  # The default entry is stored WITHOUT @ref, so a future PATTERNS_KIT_REF bump
  # keeps applying while the user's explicit pin is untouched.
  grep -Fq 'kit_sources:' "$XDG_CONFIG_HOME/acq/config.yaml"
  refute grep -Fq "agentic-coding-patterns@$PATTERNS_KIT_REF" "$XDG_CONFIG_HOME/acq/config.yaml"

  run acq_kit_sources_entries
  assert_success
  assert_output --partial "agentic-coding-patterns|$PATTERNS_KIT_REF|"
  assert_output --partial 'mogul/kits|abcd|'
}

@test "an explicitly pinned default source keeps its own ref" {
  run "$ACQ" kit-source add github.com/GSA-TTS/agentic-coding-patterns --ref deadbeef
  assert_success

  run acq_kit_sources_entries
  assert_success
  assert_output --partial 'agentic-coding-patterns|deadbeef|'
  refute_output --partial "agentic-coding-patterns|$PATTERNS_KIT_REF|"
}

@test "an unresolvable provider_kit blocks create/run but not the management verbs" {
  _acq_config_write_field provider_kit 'evil-kits/x-provider'

  # Building the kit list LATCHES the error instead of aborting: every verb runs
  # it via acq_resolve_backend, and configure/kit-source are how the user repairs
  # the config. The latch only becomes fatal at the create/run gate. Called
  # directly (not via `run`, which runs in a subshell and would drop the latch).
  _build_kit_list
  run _acq_require_provider_selection
  assert_failure
  assert_output --partial 'could not be resolved'

  # Management verbs keep working with the broken config in place.
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 "$ACQ" configure
  assert_success
  run env ACQ_BACKEND=msb "$ACQ" kit-source add github.com/acme/other --ref abc123
  assert_success

  # create/run fail closed rather than shipping a sandbox without the provider.
  local proj="$STUBDIR/bad-provider-proj"; mkdir -p "$proj"
  rm -f "$STUBDIR/.msb_created"
  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 STUB_OPENCODE_OK=1 "$ACQ" create shell "$proj"
  assert_failure
  assert_output --partial 'provider kit could not be resolved'
  refute [ -f "$STUBDIR/.msb_created" ]

  run env ACQ_BACKEND=msb ACQ_NO_PROMPT=1 STUB_OPENCODE_OK=1 "$ACQ" run shell "$proj"
  assert_failure
  assert_output --partial 'provider kit could not be resolved'
}

@test "provider_kit from config refuses an untrusted remote ref" {
  _acq_config_write_field provider_kit 'git+https://github.com/evil/kits.git#ref=abc123&dir=kits'

  run acq_provider_kit_ref
  assert_failure
  assert_output --partial 'untrusted remote ref'
  assert_output --partial 'acq kit-source add github.com/evil'
}

@test "a trusted remote ref from config is accepted" {
  run "$ACQ" kit-source add github.com/evil/kits --ref abc123
  assert_success
  _acq_config_write_field provider_kit 'git+https://github.com/evil/kits.git#ref=abc123&dir=kits'

  run acq_provider_kit_ref
  assert_success
  assert_output --partial 'github.com/evil/kits.git#ref=abc123'
}

# ---------------------------------------------------------------------------
# Trust granularity: a durable remote ref is trusted per REPOSITORY, not per owner
# ---------------------------------------------------------------------------

@test "trusting one repository does not authorize a sibling repo of the same owner" {
  run "$ACQ" kit-source add github.com/acme/trusted --ref abc123
  assert_success

  _acq_config_write_field provider_kit 'git+https://github.com/acme/untrusted.git#ref=abc123&dir=kits'
  run acq_provider_kit_ref
  assert_failure
  assert_output --partial 'untrusted remote ref'
  assert_output --partial 'acq kit-source add github.com/acme/untrusted'

  # A repository whose name merely starts with a trusted name is a different repo.
  _acq_config_write_field provider_kit 'git+https://github.com/acme/trusted-evil.git#ref=abc123&dir=kits'
  run acq_provider_kit_ref
  assert_failure
  assert_output --partial 'untrusted remote ref'

  # The trusted repository itself still resolves.
  _acq_config_write_field provider_kit 'git+https://github.com/acme/trusted.git#ref=abc123&dir=kits'
  run acq_provider_kit_ref
  assert_success
  assert_output --partial 'github.com/acme/trusted.git#ref=abc123'
}

@test "a durable remote ref that cannot be parsed to one repository fails closed" {
  run "$ACQ" kit-source add github.com/acme/trusted --ref abc123
  assert_success

  local bad
  for bad in \
    'git+https://user@github.com/acme/trusted.git#ref=abc123&dir=kits' \
    'git+https://github.com/acme/trusted/extra.git#ref=abc123&dir=kits' \
    'git+https://github.com/acme#ref=abc123&dir=kits' \
    'git+http://github.com/acme/trusted.git#ref=abc123&dir=kits' \
    'git+https://evil.example/x://github.com/acme/trusted.git#ref=abc123&dir=kits' \
    'git+https://evil.example/github.com/acme/trusted.git#ref=abc123&dir=kits' \
    'git+https://github.com/acme/trusted/.git#ref=abc123&dir=kits' \
    'git+https://github.com:8443/acme/trusted.git#ref=abc123&dir=kits' \
    'git+https://GitHub.com/acme/trusted.git#ref=abc123&dir=kits' \
    "$(printf 'git+https://github.com/acme/x\nevil.example/a/b#ref=abc123&dir=kits')"; do
    _acq_config_write_field provider_kit "$bad"
    run acq_provider_kit_ref
    assert_failure
    assert_output --partial 'untrusted remote ref'
  done
}

# ---------------------------------------------------------------------------
# kit-source rm: the backend allowlist is recomputed from what REMAINS trusted
# ---------------------------------------------------------------------------

# _plant_sbx_allowlist_stub CURRENT_JSON — an sbx whose kit.allowedSources lives
# in $STUBDIR/allowed. STUB_SET_FAIL=1 makes `settings set` fail.
_plant_sbx_allowlist_stub() {
  printf '%s\n' "$1" > "$STUBDIR/allowed"
  cat >"$STUBDIR/sbx" <<'STUB'
#!/usr/bin/env bash
{ printf 'sbx'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$CALLS"
case "${1:-}" in
  version) printf 'sbx version: v0.48.0 abc123\n' ;;
  settings)
    case "${2:-}" in
      get) cat "$STUBDIR/allowed" ;;
      set)
        [ "${STUB_SET_FAIL:-0}" = 1 ] && exit 1
        printf '%s\n' "$4" > "$STUBDIR/allowed" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBDIR/sbx"
}

@test "kit-source rm keeps a shared owner prefix while another trusted repo needs it" {
  _plant_sbx_allowlist_stub '["docker.io/","github.com/acme/"]'
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success
  run "$ACQ" kit-source add github.com/acme/two --ref bbbb
  assert_success

  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/one
  assert_success
  grep -Fq 'github.com/acme/' "$STUBDIR/allowed"
  refute grep -Fq 'settings set' "$CALLS"

  # Removing the last repository of that owner finally drops the prefix, and only
  # that prefix: unrelated entries the operator set stay put.
  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/two
  assert_success
  refute grep -Fq 'github.com/acme/' "$STUBDIR/allowed"
  grep -Fq 'docker.io/' "$STUBDIR/allowed"
}

@test "kit-source rm keeps a prefix still granted by ACQ_EXTRA_KIT_SOURCES" {
  _plant_sbx_allowlist_stub '["docker.io/","github.com/acme/"]'
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success

  run env ACQ_BACKEND=sbx ACQ_EXTRA_KIT_SOURCES='github.com/acme/' "$ACQ" kit-source rm github.com/acme/one
  assert_success
  grep -Fq 'github.com/acme/' "$STUBDIR/allowed"
}

@test "kit-source rm fails closed when the backend allowlist cannot be updated" {
  _plant_sbx_allowlist_stub '["docker.io/","github.com/acme/"]'
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success

  run env ACQ_BACKEND=sbx STUB_SET_FAIL=1 "$ACQ" kit-source rm github.com/acme/one
  assert_failure
  assert_output --partial 'still permits'
  assert_output --partial 'sbx settings set kit.allowedSources'
  assert_output --partial 'NOT removed'
  refute_output --partial "removed kit source 'github.com/acme/one'."
  # Nothing is reported as removed, so the source stays registered and the same
  # command can be retried once the backend setting is fixed.
  run acq_kit_sources_entries
  assert_output --partial 'github.com/acme/one'
  grep -Fq 'github.com/acme/' "$STUBDIR/allowed"

  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/one
  assert_success
  refute grep -Fq 'github.com/acme/' "$STUBDIR/allowed"
}

@test "kit-source rm fails closed when the backend allowlist cannot be read" {
  _plant_sbx_allowlist_stub 'not json'
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success

  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/one
  assert_failure
  assert_output --partial 'still permits'
  run acq_kit_sources_entries
  assert_output --partial 'github.com/acme/one'
}

@test "kit-source rm fails closed when jq cannot be used" {
  _plant_sbx_allowlist_stub '["docker.io/","github.com/acme/"]'
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success

  printf '#!/bin/sh\nexit 127\n' > "$STUBDIR/jq"
  chmod +x "$STUBDIR/jq"
  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/one
  assert_failure
  assert_output --partial 'still permits'
  assert_output --partial 'NOT removed'
  run acq_kit_sources_entries
  assert_output --partial 'github.com/acme/one'
}

@test "kit-source rm fails closed when the backend does not apply the update" {
  _plant_sbx_allowlist_stub '["docker.io/","github.com/acme/"]'
  # `settings set` reports success but the value does not change.
  sed -i 's|printf .%s\\n. "\$4" > "\$STUBDIR/allowed" ;;|: ;;|' "$STUBDIR/sbx"
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success

  run env ACQ_BACKEND=sbx "$ACQ" kit-source rm github.com/acme/one
  assert_failure
  assert_output --partial 'still lists it after the update'
  assert_output --partial 'NOT removed'
  run acq_kit_sources_entries
  assert_output --partial 'github.com/acme/one'
}

@test "kit-source rm still works on a backend with no allowlist (msb)" {
  run "$ACQ" kit-source add github.com/acme/one --ref aaaa
  assert_success
  run env ACQ_BACKEND=msb "$ACQ" kit-source rm github.com/acme/one
  assert_success
  run acq_kit_sources_entries
  refute_output --partial 'github.com/acme/one'
}

@test "an ACQ_EXTRA_KIT_SOURCES owner grant still needs a plain repository ref" {
  export ACQ_EXTRA_KIT_SOURCES='github.com/acme/'
  local bad
  for bad in \
    'git+https://github.com/acme/..#ref=abc123&dir=kits' \
    'git+https://github.com/acme/.#ref=abc123&dir=kits'; do
    _acq_config_write_field provider_kit "$bad"
    run acq_provider_kit_ref
    assert_failure
  done

  # The flat config reader is line-oriented, so exercise the check directly.
  run _acq_kit_source_ref_trusted "$(printf 'git+https://github.com/acme/x\nevil.example/a/b#ref=abc123&dir=kits')"
  assert_failure

  _acq_config_write_field provider_kit 'git+https://github.com/acme/anything.git#ref=abc123&dir=kits'
  run acq_provider_kit_ref
  assert_success
}
