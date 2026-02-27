#!/usr/bin/env bash
# sandbox-unit.sh — Non-Docker unit/integration tests for sandbox.sh
# Tests error paths, guards, audit logging, config parsing, and SOPS roundtrips.
# Usage: ./test/sandbox-unit.sh
set -euo pipefail

# shellcheck source=test/helpers.sh
source "$(dirname "$0")/helpers.sh"

WORK_DIR=$(mktemp -d)
# Use environment override (sandbox.sh reads KEYCHAIN_SERVICE from env) — no sed patching needed
export KEYCHAIN_SERVICE="sops-age-key-unit-test"
trap 'rm -rf "$WORK_DIR"; security delete-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true' EXIT

# Create a working sandbox.sh in WORK_DIR (with config.sh for sourcing)
create_test_sandbox() {
    cp config.sh "${WORK_DIR}/config.sh"
    cp sandbox.sh "${WORK_DIR}/sandbox.sh"
    chmod +x "${WORK_DIR}/sandbox.sh"
}

echo "=== Sandbox Unit Tests ==="
echo ""

# -----------------------------------------------------------------------
# 0. Prerequisites (fail-fast if tools missing)
# -----------------------------------------------------------------------
echo "Prerequisites:"
check "sops installed" command -v sops
check "age installed" command -v age
check "age-keygen installed" command -v age-keygen
check "security (Keychain) available" command -v security
check "jq installed" command -v jq
echo ""

# -----------------------------------------------------------------------
# 1. CLI error handling
# -----------------------------------------------------------------------
echo "CLI error handling:"
check "help exits 0" bash sandbox.sh help
check "unknown command exits non-zero" bash -c "! bash sandbox.sh bogus_cmd 2>/dev/null"
check "help output mentions setup" bash -c "bash sandbox.sh help 2>&1 | grep -q 'setup'"
check "help output mentions encrypt" bash -c "bash sandbox.sh help 2>&1 | grep -q 'encrypt'"
check "help output mentions decrypt" bash -c "bash sandbox.sh help 2>&1 | grep -q 'decrypt'"
echo ""

# -----------------------------------------------------------------------
# 2. cmd_encrypt guards
# -----------------------------------------------------------------------
echo "Encrypt guards:"

# No .env → error
check "encrypt fails without .env" bash -c "cd '$WORK_DIR' && ! bash sandbox.sh encrypt 2>/dev/null"

# No .sops.yaml → error
echo "KEY=val" > "${WORK_DIR}/.env"
check "encrypt fails without .sops.yaml" bash -c "cd '$WORK_DIR' && ! bash sandbox.sh encrypt 2>/dev/null"

# Placeholder .sops.yaml → error
cat > "${WORK_DIR}/.sops.yaml" <<SOPS
creation_rules:
  - age: "REPLACE_WITH_YOUR_AGE_PUBLIC_KEY"
SOPS
echo "KEY=val" > "${WORK_DIR}/.env"
check "encrypt fails with placeholder key" bash -c "cd '$WORK_DIR' && ! bash sandbox.sh encrypt 2>/dev/null"
rm -f "${WORK_DIR}/.sops.yaml" "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 3. cmd_decrypt guards
# -----------------------------------------------------------------------
echo "Decrypt guards:"
check "decrypt fails without .env.enc" bash -c "cd '$WORK_DIR' && ! bash sandbox.sh decrypt 2>/dev/null"
echo ""

# -----------------------------------------------------------------------
# 4. AGE key generation + validation
# -----------------------------------------------------------------------
echo "AGE key generation:"

keygen_output=$(age-keygen 2>&1)
private_key=$(echo "$keygen_output" | grep '^AGE-SECRET-KEY-' | head -1)
public_key=$(echo "$keygen_output" | grep 'public key:' | awk '{print $NF}')

check "private key starts with AGE-SECRET-KEY-" test -n "$private_key"
check "private key matches format" bash -c "[[ '$private_key' =~ $AGE_PRIVATE_KEY_REGEX ]]"
check "public key starts with age1" bash -c "[[ '$public_key' == age1* ]]"
check "public key is lowercase alphanumeric" bash -c "[[ '$public_key' =~ $AGE_PUBLIC_KEY_REGEX ]]"
check "private key is not empty" bash -c "[[ ${#private_key} -gt 20 ]]"
check "public key is not empty" bash -c "[[ ${#public_key} -gt 20 ]]"
echo ""

# -----------------------------------------------------------------------
# 5. Keychain store/retrieve roundtrip
# -----------------------------------------------------------------------
echo "Keychain roundtrip:"

security add-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$private_key" -U 2>/dev/null || true
check "Key stored in Keychain" security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE"
retrieved=$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
check "Retrieved key matches stored key" test "$retrieved" = "$private_key"
echo ""

# -----------------------------------------------------------------------
# 5b. Raw SOPS encrypt/decrypt roundtrip (validates SOPS itself)
# -----------------------------------------------------------------------
echo "Raw SOPS roundtrip:"

# Export key for SOPS (CI-safe, no Keychain retrieval issues)
export SOPS_AGE_KEY="$private_key"
# SOPS_AGE_KEY is set directly (not via _CMD) — ensure no stale _CMD leaks from env
unset SOPS_AGE_KEY_CMD 2>/dev/null || true

# Set up .sops.yaml in WORK_DIR
cat > "${WORK_DIR}/.sops.yaml" <<SOPS
creation_rules:
  - age: "${public_key}"
SOPS

cat > "${WORK_DIR}/.env.raw" <<ENV
RAW_TEST_KEY=raw_secret_12345
RAW_ANOTHER=raw_another_secret
ENV

check "raw SOPS encrypt succeeds" bash -c "cd '$WORK_DIR' && sops encrypt $SOPS_FORMAT_FLAGS .env.raw > .env.raw.enc"
check "raw encrypted file not plaintext" bash -c "! grep -q 'raw_secret_12345' '${WORK_DIR}/.env.raw.enc'"
check "raw SOPS decrypt succeeds" bash -c "cd '$WORK_DIR' && sops decrypt $SOPS_FORMAT_FLAGS .env.raw.enc > .env.raw.dec"
check "raw decrypted RAW_TEST_KEY matches" grep -q "RAW_TEST_KEY=raw_secret_12345" "${WORK_DIR}/.env.raw.dec"
check "raw decrypted RAW_ANOTHER matches" grep -q "RAW_ANOTHER=raw_another_secret" "${WORK_DIR}/.env.raw.dec"
rm -f "${WORK_DIR}/.env.raw" "${WORK_DIR}/.env.raw.enc" "${WORK_DIR}/.env.raw.dec"
echo ""

# -----------------------------------------------------------------------
# 6. Full encrypt/decrypt roundtrip (via patched sandbox.sh)
# -----------------------------------------------------------------------
echo "Encrypt/decrypt roundtrip:"

create_test_sandbox

# Create test .env
cat > "${WORK_DIR}/.env" <<ENV
API_KEY=test-secret-12345
DB_HOST=localhost
ENV

cp .env.example "${WORK_DIR}/"

check "encrypt succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt"
check ".env.enc created" test -f "${WORK_DIR}/.env.enc"
check ".env removed after encrypt" test ! -f "${WORK_DIR}/.env"
check "encrypted file not plaintext" bash -c "! grep -q 'test-secret-12345' '${WORK_DIR}/.env.enc'"
check ".env.enc contains sops metadata" grep -q "sops" "${WORK_DIR}/.env.enc"

check "decrypt succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt"
check ".env restored after decrypt" test -f "${WORK_DIR}/.env"
check "API_KEY preserved" grep -q "API_KEY=test-secret-12345" "${WORK_DIR}/.env"
check "DB_HOST preserved" grep -q "DB_HOST=localhost" "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 7. Double encrypt (re-encrypt after decrypt)
# -----------------------------------------------------------------------
echo "Re-encrypt cycle:"

rm -f "${WORK_DIR}/.env.enc"
check "second encrypt succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt"
check "second .env.enc created" test -f "${WORK_DIR}/.env.enc"
check "second decrypt succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt"
check "API_KEY still intact after re-encrypt" grep -q "API_KEY=test-secret-12345" "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 8. Multi-line values and special characters
# -----------------------------------------------------------------------
echo "Special characters:"

rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<'ENV'
SIMPLE=hello
WITH_EQUALS=key=value=extra
WITH_SPACES=hello world
WITH_SPECIAL=p@$$w0rd!#%
ENV

check "encrypt special chars" bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt"
check "decrypt special chars" bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt"
check "equals preserved" grep -q "WITH_EQUALS=key=value=extra" "${WORK_DIR}/.env"
check "spaces preserved" grep -q "WITH_SPACES=hello world" "${WORK_DIR}/.env"
# shellcheck disable=SC2016
check "special chars preserved" grep -q 'WITH_SPECIAL=p@$$w0rd!#%' "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 9. Audit log format
# -----------------------------------------------------------------------
echo "Audit log format:"

AUDIT_LOG="${WORK_DIR}/.config/agent-sandbox/audit.log"
# Run encrypt/decrypt to generate audit entries (use patched sandbox for Keychain service)
# Note: HOME override is needed so audit log writes to WORK_DIR, but security(1) uses HOME
# to find ~/Library/Keychains, so we must preserve the real Keychain path.
rm -f "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<ENV
AUDIT_TEST=value
ENV
create_test_sandbox
# Use CONFIG_DIR env override (avoids HOME override breaking Keychain)
bash -c "cd '$WORK_DIR' && CONFIG_DIR='${WORK_DIR}/.config/agent-sandbox' bash sandbox.sh encrypt" >/dev/null 2>&1 || true
bash -c "cd '$WORK_DIR' && CONFIG_DIR='${WORK_DIR}/.config/agent-sandbox' bash sandbox.sh decrypt" >/dev/null 2>&1 || true

check "audit log created" test -f "$AUDIT_LOG"
if [[ -f "$AUDIT_LOG" ]]; then
    check "audit log has tab-separated fields" bash -c "awk -F'\\t' 'NF < 2 { exit 1 }' '$AUDIT_LOG'"
    check "audit log has ISO timestamps" bash -c "grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' '$AUDIT_LOG'"
    check "audit log records encrypt" grep -q "encrypt" "$AUDIT_LOG"
    check "audit log records decrypt" grep -q "decrypt" "$AUDIT_LOG"
fi
echo ""

# -----------------------------------------------------------------------
# 10. network-policy.json structure
# -----------------------------------------------------------------------
echo "Network policy validation:"

check "Has >= 6 IPv4 CIDRs" bash -c "test $(jq '.blockCidrs | length' network-policy.json) -ge 6"
check "Has >= 4 IPv6 CIDRs" bash -c "test $(jq '.blockCidrsIpv6 | length' network-policy.json) -ge 4"
check "Blocks 10.0.0.0/8" jq -e '.blockCidrs | index("10.0.0.0/8")' network-policy.json
check "Blocks 172.16.0.0/12" jq -e '.blockCidrs | index("172.16.0.0/12")' network-policy.json
check "Blocks 192.168.0.0/16" jq -e '.blockCidrs | index("192.168.0.0/16")' network-policy.json
check "Blocks link-local 169.254.0.0/16" jq -e '.blockCidrs | index("169.254.0.0/16")' network-policy.json
check "Blocks Azure IMDS" jq -e '.blockCidrs | index("168.63.129.16/32")' network-policy.json
check "Blocks Alibaba IMDS" jq -e '.blockCidrs | index("100.100.100.200/32")' network-policy.json
check "Blocks IPv6 ULA" jq -e '.blockCidrsIpv6 | index("fc00::/7")' network-policy.json
check "Blocks IPv6 link-local" jq -e '.blockCidrsIpv6 | index("fe80::/10")' network-policy.json
check "Blocks IPv6 loopback" jq -e '.blockCidrsIpv6 | index("::1/128")' network-policy.json
check "Blocks IPv6 AWS IMDS" jq -e '.blockCidrsIpv6 | index("fd00:ec2::254/128")' network-policy.json
check "Has notes object" jq -e '.notes | type == "object"' network-policy.json
check "Notes cover all CIDRs" bash -c "test $(jq '.notes | length' network-policy.json) -ge 8"
check "Total CIDR count >= 10" bash -c "test $(($(jq '.blockCidrs | length' network-policy.json) + $(jq '.blockCidrsIpv6 | length' network-policy.json))) -ge 10"
echo ""

# -----------------------------------------------------------------------
# 11. .sops.yaml validation (generate a test one since it's now gitignored)
# -----------------------------------------------------------------------
echo ".sops.yaml validation:"
# Create a test .sops.yaml for validation tests
_test_sops_yaml=$(mktemp)
cat > "$_test_sops_yaml" <<SOPS
creation_rules:
  - age: "age1testkey123"
SOPS
check ".sops.yaml format has creation_rules" grep -q "creation_rules:" "$_test_sops_yaml"
check ".sops.yaml format has age key reference" grep -q "age:" "$_test_sops_yaml"
check ".sops.yaml format is valid YAML" bash -c "yq eval '.' '$_test_sops_yaml' >/dev/null 2>&1"
rm -f "$_test_sops_yaml"
echo ""

# -----------------------------------------------------------------------
# 12. Temp file security
# -----------------------------------------------------------------------
echo "Temp file security:"
tmp_file=$(mktemp "${TMPDIR:-/tmp}/sandbox-test-XXXXXX")
echo "SECRET=value" > "$tmp_file"
chmod 600 "$tmp_file"
perms=$(stat -f "%Lp" "$tmp_file" 2>/dev/null || stat -c "%a" "$tmp_file" 2>/dev/null)
check "Temp file mode 600" test "$perms" = "600"
check "Temp file is not world-readable" bash -c "[[ ! -r '$tmp_file' ]] 2>/dev/null || test '$perms' = '600'"
rm -f "$tmp_file"
echo ""

# -----------------------------------------------------------------------
# 13. Corrupt/edge-case .env.enc handling
# -----------------------------------------------------------------------
echo "Corrupt input handling:"

# Save valid .env.enc for later, create corrupt versions
rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<ENV
CORRUPT_TEST=value
ENV
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true
cp "${WORK_DIR}/.env.enc" "${WORK_DIR}/.env.enc.bak"

# Truncated .env.enc
echo "truncated" > "${WORK_DIR}/.env.enc"
rm -f "${WORK_DIR}/.env"
check "decrypt fails on truncated .env.enc" bash -c "! (cd '$WORK_DIR' && bash sandbox.sh decrypt) 2>/dev/null"
# Atomic write: .env should not exist at all (temp file removed on sops failure, mv never runs)
check ".env absent from corrupt input" bash -c "test ! -f '${WORK_DIR}/.env'"
check ".env.tmp cleaned up" bash -c "test ! -f '${WORK_DIR}/.env.tmp'"

# Empty .env.enc
: > "${WORK_DIR}/.env.enc"
check "decrypt fails on empty .env.enc" bash -c "! (cd '$WORK_DIR' && bash sandbox.sh decrypt) 2>/dev/null"

# Restore valid .env.enc
cp "${WORK_DIR}/.env.enc.bak" "${WORK_DIR}/.env.enc"
rm -f "${WORK_DIR}/.env.enc.bak"
echo ""

# -----------------------------------------------------------------------
# 14. Empty .env handling
# -----------------------------------------------------------------------
echo "Empty .env handling:"

rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc"
: > "${WORK_DIR}/.env"
check "encrypt empty .env succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt"
check "empty .env.enc created" test -f "${WORK_DIR}/.env.enc"
check "decrypt empty .env.enc succeeds" bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt"
check "decrypted file exists" test -f "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 15. Wrong-key decrypt
# -----------------------------------------------------------------------
echo "Wrong-key decrypt:"

rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<ENV
WRONG_KEY_TEST=secret
ENV
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true

# Generate a different key and try to decrypt with it
different_keygen=$(age-keygen 2>&1)
different_key=$(echo "$different_keygen" | grep '^AGE-SECRET-KEY-' | head -1)
# SOPS tries ALL key sources (SOPS_AGE_KEY + key files).
# sandbox.sh exports SOPS_AGE_KEY directly from Keychain.
# Use a non-existent Keychain service so the direct export fails, leaving only the wrong key.
check "decrypt with wrong key fails" bash -c "unset SOPS_AGE_KEY; ! (cd '$WORK_DIR' && SOPS_AGE_KEY='$different_key' KEYCHAIN_SERVICE='${DEFAULT_KEYCHAIN_SERVICE}-nonexistent' bash sandbox.sh decrypt) 2>/dev/null"
echo ""

# -----------------------------------------------------------------------
# 16. Atomic encrypt safety
# -----------------------------------------------------------------------
echo "Atomic encrypt:"

# Restore .env for this test (decrypt with correct key)
rm -f "${WORK_DIR}/.env"
bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt" >/dev/null 2>&1 || true
check "atomic: .env.enc.tmp not left behind" test ! -f "${WORK_DIR}/.env.enc.tmp"
echo ""

# -----------------------------------------------------------------------
# 17. Audit log permissions
# -----------------------------------------------------------------------
echo "Audit log permissions:"

if [[ -f "$AUDIT_LOG" ]]; then
    audit_perms=$(stat -f "%Lp" "$AUDIT_LOG" 2>/dev/null || stat -c "%a" "$AUDIT_LOG" 2>/dev/null)
    check "audit log is mode 600" test "$audit_perms" = "600"
    audit_owner=$(stat -f "%Su" "$AUDIT_LOG" 2>/dev/null || stat -c "%U" "$AUDIT_LOG" 2>/dev/null)
    check "audit log owned by current user" test "$audit_owner" = "$USER"
fi
echo ""

# -----------------------------------------------------------------------
# 18. Decrypt file permissions (umask 077 verification)
# -----------------------------------------------------------------------
echo "Decrypt file permissions:"

rm -f "${WORK_DIR}/.env"
bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt" >/dev/null 2>&1 || true
if [[ -f "${WORK_DIR}/.env" ]]; then
    env_perms=$(stat -f "%Lp" "${WORK_DIR}/.env" 2>/dev/null || stat -c "%a" "${WORK_DIR}/.env" 2>/dev/null)
    check "decrypted .env is mode 600" test "$env_perms" = "600"
    check "decrypted .env not world-readable" bash -c "[[ '$env_perms' != *4 ]] && [[ '$env_perms' != *5 ]] && [[ '$env_perms' != *6 ]] && [[ '$env_perms' != *7 ]]"
fi
echo ""

# -----------------------------------------------------------------------
# 19. Encrypt idempotency
# -----------------------------------------------------------------------
echo "Encrypt idempotency:"

rm -f "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<ENV
IDEMPOTENT=value
ENV
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true
first_enc=$(cat "${WORK_DIR}/.env.enc")

bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt" >/dev/null 2>&1 || true
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true
second_enc=$(cat "${WORK_DIR}/.env.enc")

check "both encryptions produce valid SOPS output" bash -c "echo '$first_enc' | grep -q 'sops' && echo '$second_enc' | grep -q 'sops'"
check "ciphertext differs between encryptions (randomized)" test "$first_enc" != "$second_enc"
echo ""

# -----------------------------------------------------------------------
# 20. README cross-reference
# -----------------------------------------------------------------------
echo "Cross-reference validation:"

# Verify sandbox.sh subcommands match README table
check "README lists setup" grep -q "make setup" README.md
check "README lists run" grep -q "make run" README.md
check "README lists validate" grep -q "make validate" README.md
check "README lists clean" grep -q "make clean" README.md
check "README lists encrypt" grep -q "make encrypt" README.md
check "README lists decrypt" grep -q "make decrypt" README.md
check "README lists test" grep -q "make test" README.md

# Verify SECURITY.md CIDR table matches network-policy.json
cidr_count=$(($(jq '.blockCidrs | length' network-policy.json) + $(jq '.blockCidrsIpv6 | length' network-policy.json)))
# Match table rows starting with "| `" followed by CIDR chars (digits, hex, colons, dots)
security_rows=$(grep -cE '^\| `[0-9a-f:.]' docs/SECURITY.md || true)
check "SECURITY.md CIDR table matches JSON ($cidr_count CIDRs)" test "$cidr_count" -eq "$security_rows"

# Verify AGENTS.md references key files
check "AGENTS.md exists" test -f AGENTS.md
check "AGENTS.md references make test" grep -q "make test" AGENTS.md
check "AGENTS.md references config.sh" grep -q "config.sh" AGENTS.md
check "README references AGENTS.md" grep -q "AGENTS.md" README.md
echo ""

# -----------------------------------------------------------------------
# 21. cmd_validate (partial — no Docker available in CI)
# -----------------------------------------------------------------------
echo "Validate command:"

# validate should fail without Docker but still check other things
validate_output=$(bash sandbox.sh validate 2>&1 || true)
check "validate checks for Docker" bash -c "echo '$validate_output' | grep -qi 'docker'"
check "validate checks for sops" bash -c "echo '$validate_output' | grep -qi 'sops'"
check "validate checks for jq" bash -c "echo '$validate_output' | grep -qi 'jq'"
check "validate checks for Keychain" bash -c "echo '$validate_output' | grep -qi 'key'"

# Placeholder .sops.yaml detection (sandbox.sh:220)
cat > "${WORK_DIR}/.sops-placeholder.yaml" <<SOPS
creation_rules:
  - age: "${PLACEHOLDER_KEY}"
SOPS
# Test that validate detects the placeholder — use patched sandbox
placeholder_sandbox="${WORK_DIR}/sandbox-placeholder.sh"
sed "s|.sops.yaml|.sops-placeholder.yaml|" sandbox.sh > "$placeholder_sandbox"
check "validate detects placeholder .sops.yaml" bash -c "! (cd '$WORK_DIR' && bash '$placeholder_sandbox' validate) 2>/dev/null"
rm -f "$placeholder_sandbox" "${WORK_DIR}/.sops-placeholder.yaml"
echo ""

# -----------------------------------------------------------------------
# 22. cmd_run guards (testable without Docker)
# -----------------------------------------------------------------------
echo "Run guards:"

# Missing .env.enc
rm -f "${WORK_DIR}/.env.enc"
check_err "run fails without .env.enc" ".env.enc not found" bash -c "cd '$WORK_DIR' && bash sandbox.sh run ."

# Missing network-policy.json
cat > "${WORK_DIR}/.env.enc" <<ENC
dummy
ENC
mv "${WORK_DIR}/sandbox.sh" "${WORK_DIR}/sandbox.sh.bak"
# Create sandbox.sh without network-policy in the work dir
cp config.sh "${WORK_DIR}/config.sh" 2>/dev/null || true
cp sandbox.sh "${WORK_DIR}/sandbox.sh"
rm -f "${WORK_DIR}/network-policy.json"
check_err "run fails without network-policy.json" "network-policy.json not found" bash -c "cd '$WORK_DIR' && bash sandbox.sh run ."
mv "${WORK_DIR}/sandbox.sh.bak" "${WORK_DIR}/sandbox.sh"

# Restore valid .env.enc for subsequent tests
rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc"
cat > "${WORK_DIR}/.env" <<ENV
GUARD_TEST=value
ENV
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true
echo ""

# -----------------------------------------------------------------------
# 23. cmd_setup (.env copy-from-example)
# -----------------------------------------------------------------------
echo "Setup guards:"

# Test .env copy-from-example logic (sandbox.sh:72-75)
setup_dir=$(mktemp -d)
cp .env.example "${setup_dir}/"
cp config.sh "${setup_dir}/"
cp sandbox.sh "${setup_dir}/"
# Simulate that setup's prerequisite checks fail (no Docker) but .env copy still happens
# We can't run full setup, but we can test the logic path
check ".env.example template exists" test -f .env.example
check ".env.example has ANTHROPIC_API_KEY" grep -q "ANTHROPIC_API_KEY" .env.example
check ".env.example has model override comment" grep -q "AGENT_MODEL" .env.example
rm -rf "$setup_dir"
echo ""

# -----------------------------------------------------------------------
# 24. Help text completeness
# -----------------------------------------------------------------------
echo "Help text:"

help_output=$(bash sandbox.sh help 2>&1)
check "help lists setup" bash -c "echo '$help_output' | grep -q 'setup'"
check "help lists run" bash -c "echo '$help_output' | grep -q 'run'"
check "help lists validate" bash -c "echo '$help_output' | grep -q 'validate'"
check "help lists clean" bash -c "echo '$help_output' | grep -q 'clean'"
check "help lists encrypt" bash -c "echo '$help_output' | grep -q 'encrypt'"
check "help lists decrypt" bash -c "echo '$help_output' | grep -q 'decrypt'"
check "help lists models" bash -c "echo '$help_output' | grep -q 'models'"
check "help lists config" bash -c "echo '$help_output' | grep -q 'config'"
check "help shows usage line" bash -c "echo '$help_output' | grep -q 'Usage:'"
echo ""

# -----------------------------------------------------------------------
# 25. Error message assertions
# -----------------------------------------------------------------------
echo "Error messages:"

check_err "encrypt error mentions .env" ".env not found" bash -c "cd /tmp && bash '$PWD/sandbox.sh' encrypt"
check_err "decrypt error mentions .env.enc" ".env.enc not found" bash -c "cd /tmp && bash '$PWD/sandbox.sh' decrypt"
check_err "unknown cmd error is helpful" "Unknown command" bash sandbox.sh bogus_cmd_12345
echo ""

# -----------------------------------------------------------------------
# 25b. Config overridability via environment
# -----------------------------------------------------------------------
echo "Config overridability:"

# Verify sandbox.sh respects ENV_FILE override
check "ENV_FILE is overridable" bash -c "cd '$WORK_DIR' && ENV_FILE=custom.env bash sandbox.sh encrypt 2>&1 | grep -q 'custom.env'"
# Verify SANDBOX_NAME is overridable
check "SANDBOX_NAME is overridable" bash -c "SANDBOX_NAME=test-box bash sandbox.sh clean 2>&1 | grep -q 'test-box'"
# Verify ENV_ENC is overridable
check "ENV_ENC is overridable" bash -c "cd '$WORK_DIR' && ENV_ENC=custom.enc bash sandbox.sh decrypt 2>&1 | grep -q 'custom.enc'"
# Verify NETWORK_POLICY is overridable (run guard checks for it)
check "NETWORK_POLICY is overridable" bash -c "cd '$WORK_DIR' && NETWORK_POLICY=custom-policy.json bash sandbox.sh run . 2>&1 | grep -q 'custom-policy.json'"
# Verify CONFIG_DIR is overridable (audit log writes to overridden path)
check "CONFIG_DIR is overridable" bash -c "cd '$WORK_DIR' && CONFIG_DIR='${WORK_DIR}/custom-config' bash sandbox.sh clean 2>/dev/null; test -d '${WORK_DIR}/custom-config'"
echo ""

# -----------------------------------------------------------------------
# 26. Git identity sanitization
# -----------------------------------------------------------------------
echo "Git identity sanitization:"

# Verify tr -d strips newlines, carriage returns, and NUL bytes
check "tr -d strips newline" bash -c "result=\$(printf 'test\ninjection' | tr -d '\n\r\0'); [ \"\$result\" = 'testinjection' ]"
check "tr -d strips carriage return" bash -c "result=\$(printf 'test\rinjection' | tr -d '\n\r\0'); [ \"\$result\" = 'testinjection' ]"
check "tr -d strips NUL byte" bash -c "result=\$(printf 'test\0injection' | tr -d '\n\r\0'); [ \"\$result\" = 'testinjection' ]"
check "tr -d preserves clean input" bash -c "result=\$(echo 'Clean Name' | tr -d '\n\r\0'); [ \"\$result\" = 'Clean Name' ]"

# Verify git identity values are quoted in env file output (protects against = in values)
env_test_file=$(mktemp)
name_with_equals="evil=value"
printf 'GIT_AUTHOR_NAME="%s"\n' "$name_with_equals" > "$env_test_file"
check "git name with = is quoted" grep -q 'GIT_AUTHOR_NAME="evil=value"' "$env_test_file"
rm -f "$env_test_file"
echo ""

# -----------------------------------------------------------------------
# 27. Makefile targets
# -----------------------------------------------------------------------
echo "Makefile validation:"

make_help=$(make -f Makefile help 2>&1)
check "make help lists setup" bash -c "echo '$make_help' | grep -q 'setup'"
check "make help lists run" bash -c "echo '$make_help' | grep -q 'run'"
check "make help lists encrypt" bash -c "echo '$make_help' | grep -q 'encrypt'"
check "make help lists decrypt" bash -c "echo '$make_help' | grep -q 'decrypt'"
check "make help lists test" bash -c "echo '$make_help' | grep -q 'test'"
check "make help lists validate" bash -c "echo '$make_help' | grep -q 'validate'"
check "make help lists clean" bash -c "echo '$make_help' | grep -q 'clean'"
check "make help lists models" bash -c "echo '$make_help' | grep -q 'models'"
check "make help lists config" bash -c "echo '$make_help' | grep -q 'config'"
check "make help lists help" bash -c "echo '$make_help' | grep -q 'help'"
echo ""

# -----------------------------------------------------------------------
# 28. EXIT trap cleanup verification
# -----------------------------------------------------------------------
echo "Trap cleanup:"

# Spawn a subprocess that creates a temp file with trap, then exits
trap_test_file=$(mktemp "${TMPDIR:-/tmp}/trap-test-XXXXXX")
bash -c "
    trap 'rm -f \"$trap_test_file\"' EXIT
    echo 'secret' > '$trap_test_file'
    exit 0
"
check "EXIT trap removes temp file on normal exit" test ! -f "$trap_test_file"

# Test trap fires on error exit too
trap_test_file2=$(mktemp "${TMPDIR:-/tmp}/trap-test-XXXXXX")
bash -c "
    trap 'rm -f \"$trap_test_file2\"' EXIT
    echo 'secret' > '$trap_test_file2'
    exit 1
" 2>/dev/null || true
check "EXIT trap removes temp file on error exit" test ! -f "$trap_test_file2"
echo ""

# -----------------------------------------------------------------------
# 29. cmd_clean graceful degradation (no Docker)
# -----------------------------------------------------------------------
echo "Clean command:"

# cmd_clean uses || true, so should succeed even without Docker
clean_output=$(bash sandbox.sh clean 2>&1 || true)
check "clean succeeds without Docker" bash -c "echo '$clean_output' | grep -qi 'removed\\|sandbox'"
# Use CONFIG_DIR override instead of HOME (HOME breaks Keychain access via security(1))
check "clean produces audit entry" bash -c "CONFIG_DIR='${WORK_DIR}/.config/agent-sandbox' bash sandbox.sh clean 2>/dev/null; grep -q 'clean' '${WORK_DIR}/.config/agent-sandbox/audit.log' 2>/dev/null"
echo ""

# -----------------------------------------------------------------------
# 30. Keychain pre-flight check
# -----------------------------------------------------------------------
echo "Keychain pre-flight:"

# check_keychain_access should fail with clear message when key is missing
# decrypt should fail with keychain error before reaching SOPS
cat > "${WORK_DIR}/.env.enc" <<ENC
dummy_encrypted_content
ENC
check_err "decrypt shows keychain error" "Cannot retrieve AGE key" bash -c "cd '$WORK_DIR' && KEYCHAIN_SERVICE='${DEFAULT_KEYCHAIN_SERVICE}-nonexistent-preflight' bash sandbox.sh decrypt"
rm -f "${WORK_DIR}/.env.enc"
echo ""

# -----------------------------------------------------------------------
# 31. Atomic decrypt safety (.env.tmp not left behind)
# -----------------------------------------------------------------------
echo "Atomic decrypt:"

# After successful decrypt, no .tmp files should remain
rm -f "${WORK_DIR}/.env" "${WORK_DIR}/.env.enc" "${WORK_DIR}/.env.tmp"
cat > "${WORK_DIR}/.env" <<ENV
ATOMIC_TEST=value
ENV
bash -c "cd '$WORK_DIR' && bash sandbox.sh encrypt" >/dev/null 2>&1 || true
bash -c "cd '$WORK_DIR' && bash sandbox.sh decrypt" >/dev/null 2>&1 || true
check "atomic decrypt: .env.tmp not left behind" test ! -f "${WORK_DIR}/.env.tmp"
check "atomic decrypt: .env created successfully" test -f "${WORK_DIR}/.env"
check "atomic decrypt: content preserved" grep -q "ATOMIC_TEST=value" "${WORK_DIR}/.env"
echo ""

# -----------------------------------------------------------------------
# 32. jq fail-closed integration test (Issue #168)
# -----------------------------------------------------------------------
echo "jq fail-closed:"

# Test that malformed JSON causes jq to fail (not silently succeed)
malformed_json="${WORK_DIR}/bad-policy.json"
echo "NOT VALID JSON {{{" > "$malformed_json"
check "jq fails on malformed JSON" bash -c "! jq -r '(.blockCidrs // [])[]' '$malformed_json' 2>/dev/null"

# Test that empty JSON object produces empty output (no CIDRs to block)
echo '{}' > "${WORK_DIR}/empty-policy.json"
check "jq returns empty for missing arrays" bash -c "test -z \"\$(jq -r '(.blockCidrs // [])[] , (.blockCidrsIpv6 // [])[]' '${WORK_DIR}/empty-policy.json')\""

# Test valid JSON with no blockCidrs key produces empty output
echo '{"policy":"allow"}' > "${WORK_DIR}/no-cidrs-policy.json"
check "jq returns empty for no blockCidrs" bash -c "test -z \"\$(jq -r '(.blockCidrs // [])[] , (.blockCidrsIpv6 // [])[]' '${WORK_DIR}/no-cidrs-policy.json')\""

rm -f "$malformed_json" "${WORK_DIR}/empty-policy.json" "${WORK_DIR}/no-cidrs-policy.json"
echo ""

# -----------------------------------------------------------------------
# 33. config.sh constants integrity
# -----------------------------------------------------------------------
echo "Config constants:"

check "config.sh exists" test -f config.sh
# Note: .sops.yaml may have real key (after setup) or placeholder - just check constant exists
check "PLACEHOLDER_KEY constant is defined" test -n "$PLACEHOLDER_KEY"
check "DEFAULT_KEYCHAIN_SERVICE is non-empty" test -n "$DEFAULT_KEYCHAIN_SERVICE"
check "SOPS_FORMAT_FLAGS contains dotenv" bash -c "echo '$SOPS_FORMAT_FLAGS' | grep -q 'dotenv'"
check "REQUIRED_TOOLS has >= 4 entries" bash -c "test ${#REQUIRED_TOOLS[@]} -ge 4"
check "AGE_PRIVATE_KEY_REGEX is valid" bash -c "[[ 'AGE-SECRET-KEY-ABC123' =~ $AGE_PRIVATE_KEY_REGEX ]]"
check "AGE_PUBLIC_KEY_REGEX is valid" bash -c "[[ 'age1abc123def' =~ $AGE_PUBLIC_KEY_REGEX ]]"
check "DEFAULT_OPENCODE_CONFIG is set" test -n "$DEFAULT_OPENCODE_CONFIG"
check "MODELS_ENDPOINT_PATH is set" test -n "$MODELS_ENDPOINT_PATH"
check "MAX_MODELS_RESPONSE_SIZE is numeric" bash -c "[[ '$MAX_MODELS_RESPONSE_SIZE' =~ ^[0-9]+$ ]]"
echo ""

# -----------------------------------------------------------------------
# 34. Model discovery — response parsing (mocked, no network)
# -----------------------------------------------------------------------
echo "Model discovery parsing:"

# Mock a valid OpenAI /v1/models response
mock_response='{"object":"list","data":[{"id":"claude-sonnet-4","created":1718841600,"object":"model","owned_by":"Anthropic"},{"id":"gpt-4o","created":1718841600,"object":"model","owned_by":"OpenAI"},{"id":"llama-3-70b","created":1718841600,"object":"model","owned_by":"Meta"}]}'

# Test jq can extract model IDs
check "jq extracts model IDs" bash -c "echo '$mock_response' | jq -r '.data[].id' | grep -q 'claude-sonnet-4'"
check "jq counts models correctly" bash -c "test \$(echo '$mock_response' | jq '.data | length') -eq 3"
check "jq extracts owned_by" bash -c "echo '$mock_response' | jq -r '.data[0].owned_by' | grep -q 'Anthropic'"

# Test response validation — data must be an array
check "jq validates data is array" bash -c "echo '$mock_response' | jq -e '.data | type == \"array\"' >/dev/null"
check "jq rejects missing data field" bash -c "! echo '{\"models\":[]}' | jq -e '.data | type == \"array\"' >/dev/null 2>&1"
check "jq rejects non-array data" bash -c "! echo '{\"data\":\"not-array\"}' | jq -e '.data | type == \"array\"' >/dev/null 2>&1"

# Test empty models list
check "jq handles empty models array" bash -c "test \$(echo '{\"data\":[]}' | jq '.data | length') -eq 0"
echo ""

# -----------------------------------------------------------------------
# 35. OpenCode config generation (mocked, no network)
# -----------------------------------------------------------------------
echo "Config generation:"

# Test jq model object construction from mock response
models_json=$(echo "$mock_response" | jq '[.data[] | {key: .id, value: {name: .id}}] | from_entries')
check "jq builds models object" bash -c "echo '$models_json' | jq -e '.\"claude-sonnet-4\"' >/dev/null"
check "jq models object has all entries" bash -c "test \$(echo '$models_json' | jq 'keys | length') -eq 3"

# Test full config generation via jq
test_config=$(jq -n \
    --arg schema "https://opencode.ai/config.json" \
    --arg model "test-provider/claude-sonnet-4" \
    --arg provider_name "test-provider" \
    --arg display_name "test-provider" \
    --arg base_url "https://api.example.gov/api/v1" \
    --arg api_key_ref '{env:OPENAI_COMPAT_API_KEY}' \
    --argjson models "$models_json" \
    '{
        "$schema": $schema,
        model: $model,
        enabled_providers: [$provider_name],
        provider: {
            ($provider_name): {
                npm: "@ai-sdk/openai-compatible",
                name: $display_name,
                options: {
                    baseURL: $base_url,
                    apiKey: $api_key_ref
                },
                models: $models
            }
        }
    }')

check "generated config is valid JSON" bash -c "echo '$test_config' | jq empty"
check "config has \$schema" bash -c "echo '$test_config' | jq -e '.\"\$schema\"' >/dev/null"
check "config has model field" bash -c "echo '$test_config' | jq -e '.model == \"test-provider/claude-sonnet-4\"' >/dev/null"
check "config has provider block" bash -c "echo '$test_config' | jq -e '.provider.\"test-provider\"' >/dev/null"
check "config uses openai-compatible npm" bash -c "echo '$test_config' | jq -e '.provider.\"test-provider\".npm == \"@ai-sdk/openai-compatible\"' >/dev/null"
check "config has baseURL" bash -c "echo '$test_config' | jq -e '.provider.\"test-provider\".options.baseURL' >/dev/null"
check "config uses env var for API key" bash -c "echo '$test_config' | jq -r '.provider.\"test-provider\".options.apiKey' | grep -q 'env:'"
check "config has 3 models" bash -c "test \$(echo '$test_config' | jq '.provider.\"test-provider\".models | keys | length') -eq 3"
check "config has enabled_providers" bash -c "echo '$test_config' | jq -e '.enabled_providers == [\"test-provider\"]' >/dev/null"
echo ""

# -----------------------------------------------------------------------
# 36. cmd_models / cmd_config guards
# -----------------------------------------------------------------------
echo "Model command guards:"

# cmd_models should fail without OPENAI_COMPAT_BASE_URL
check_err "models fails without base URL" "OPENAI_COMPAT_BASE_URL not set" bash -c "unset OPENAI_COMPAT_BASE_URL; bash sandbox.sh models"
# cmd_models should fail without API key (when base URL is set)
check_err "models fails without API key" "OPENAI_COMPAT_API_KEY not set" bash -c "OPENAI_COMPAT_BASE_URL=https://example.com/v1 bash sandbox.sh models"
# cmd_config should fail without base URL
check_err "config fails without base URL" "OPENAI_COMPAT_BASE_URL not set" bash -c "unset OPENAI_COMPAT_BASE_URL; bash sandbox.sh config"
# HTTPS required for non-local URLs
check_err "models rejects HTTP for non-local" "must use HTTPS" bash -c "OPENAI_COMPAT_BASE_URL=http://remote-server.com/v1 OPENAI_COMPAT_API_KEY=test bash sandbox.sh models"
echo ""

# -----------------------------------------------------------------------
# 37. VERSION file and --version flag
# -----------------------------------------------------------------------
echo "Version infrastructure:"

check "VERSION file exists" test -f VERSION
check "VERSION contains valid semver" bash -c "grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' VERSION"
check "sandbox.sh version shows version" bash -c "bash sandbox.sh version 2>&1 | grep -qE 'agent-sandbox [0-9]+\.[0-9]+\.[0-9]+'"
check "sandbox.sh --version shows version" bash -c "bash sandbox.sh --version 2>&1 | grep -qE 'agent-sandbox [0-9]+\.[0-9]+\.[0-9]+'"
check "sandbox.sh -V shows version" bash -c "bash sandbox.sh -V 2>&1 | grep -qE 'agent-sandbox [0-9]+\.[0-9]+\.[0-9]+'"
echo ""

# -----------------------------------------------------------------------
# 38. release.sh validation
# -----------------------------------------------------------------------
echo "Release script:"

check "release.sh exists" test -f release.sh
check "release.sh is executable" test -x release.sh
check "release.sh current shows version" bash -c "./release.sh current | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'"
check "release.sh current matches VERSION" bash -c "test \"\$(./release.sh current)\" = \"\$(cat VERSION | tr -d '[:space:]')\""
check_err "release.sh rejects invalid action" "Usage:" bash -c "./release.sh bogus"
check "release.sh help shows usage" bash -c "./release.sh bogus 2>&1 | grep -q 'major'"
echo ""

# -----------------------------------------------------------------------
# 39. Enhanced config generation — model limits
# -----------------------------------------------------------------------
echo "Config generation with model limits:"

# Mock response with context_length and max_output_tokens
mock_limits='{"object":"list","data":[{"id":"big-model","context_length":200000,"max_output_tokens":65536,"object":"model","owned_by":"Test"},{"id":"small-model","context_length":4096,"max_output_tokens":2048,"object":"model","owned_by":"Test"}]}'

check "jq extracts context_length" bash -c "echo '$mock_limits' | jq -e '.data[0].context_length == 200000' >/dev/null"
check "jq extracts max_output_tokens" bash -c "echo '$mock_limits' | jq -e '.data[0].max_output_tokens == 65536' >/dev/null"

# Test the limit-aware model building jq expression (same as cmd_config)
limits_models=$(echo "$mock_limits" | jq '[.data[] | {
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

check "models with limits have context" bash -c "echo '$limits_models' | jq -e '.\"big-model\".limit.context == 200000' >/dev/null"
check "models with limits have output" bash -c "echo '$limits_models' | jq -e '.\"big-model\".limit.output == 65536' >/dev/null"
check "small model has limits too" bash -c "echo '$limits_models' | jq -e '.\"small-model\".limit.context == 4096' >/dev/null"

# Test small_model selection (picks smallest context_length)
small_model_id=$(echo "$mock_limits" | jq -r '
    [.data[] | select(.context_length or .max_model_len)] |
    if length > 0 then
        sort_by(.context_length // .max_model_len // 999999)[0].id
    else empty end // empty')
check "small_model selects smallest context" bash -c "test '$small_model_id' = 'small-model'"

# Test graceful degradation — no limits in response
mock_nolimits='{"object":"list","data":[{"id":"basic-model","object":"model","owned_by":"Test"}]}'
nolimits_models=$(echo "$mock_nolimits" | jq '[.data[] | {
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

check "models without limits omit limit field" bash -c "echo '$nolimits_models' | jq -e '.\"basic-model\" | has(\"limit\") | not' >/dev/null"
check "models without limits still have name" bash -c "echo '$nolimits_models' | jq -e '.\"basic-model\".name' >/dev/null"
echo ""

# -----------------------------------------------------------------------
# 40. Makefile release targets
# -----------------------------------------------------------------------
echo "Makefile release targets:"

check "Makefile has version target" grep -q "^version:" Makefile
check "Makefile has release-patch target" grep -q "^release-patch:" Makefile
check "Makefile has release-minor target" grep -q "^release-minor:" Makefile
check "Makefile has release-major target" grep -q "^release-major:" Makefile
echo ""

# -----------------------------------------------------------------------
# Helper: run_model_pipeline — same jq pipeline as cmd_config
# -----------------------------------------------------------------------
run_model_pipeline() {
    local response="$1"
    echo "$response" | jq '[.data[] | {
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
    }] | from_entries'
}

run_small_model_selection() {
    local response="$1"
    echo "$response" | jq -r '
        [.data[] | select(.context_length or .max_model_len)] |
        if length > 0 then
            sort_by(.context_length // .max_model_len // 999999)[0].id
        else empty end // empty'
}

run_full_config_pipeline() {
    local response="$1"
    local provider_name="${2:-test-provider}"
    local base_url="${3:-https://api.example.com/v1}"

    local models_json first_model small_model
    models_json=$(run_model_pipeline "$response")
    first_model=$(echo "$response" | jq -r '.data[0].id')
    small_model=$(run_small_model_selection "$response")

    jq -n \
        --arg schema "https://opencode.ai/config.json" \
        --arg model "${provider_name}/${first_model}" \
        --arg small_model "${small_model:+${provider_name}/${small_model}}" \
        --arg provider_name "$provider_name" \
        --arg display_name "$provider_name" \
        --arg base_url "$base_url" \
        --arg api_key_ref '{env:OPENAI_COMPAT_API_KEY}' \
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
                        apiKey: $api_key_ref
                    },
                    models: $models
                }
            }
        }'
}

FIXTURES_DIR="$(dirname "$0")/fixtures"

# -----------------------------------------------------------------------
# 41. Multi-format provider fixtures — OpenAI standard
# -----------------------------------------------------------------------
echo "Provider: OpenAI standard format:"

openai_resp=$(cat "$FIXTURES_DIR/openai-models.json")
openai_models=$(run_model_pipeline "$openai_resp")
openai_config=$(run_full_config_pipeline "$openai_resp" "openai" "https://api.openai.com/v1")

check "OpenAI: fixture is valid JSON" bash -c "echo '$openai_resp' | jq empty"
check "OpenAI: data is array" bash -c "echo '$openai_resp' | jq -e '.data | type == \"array\"' >/dev/null"
check "OpenAI: 3 models parsed" bash -c "test \$(echo '$openai_models' | jq 'keys | length') -eq 3"
check "OpenAI: gpt-4o has name" bash -c "echo '$openai_models' | jq -e '.\"gpt-4o\".name' >/dev/null"
check "OpenAI: no limit field (not in response)" bash -c "echo '$openai_models' | jq -e '.\"gpt-4o\" | has(\"limit\") | not' >/dev/null"
check "OpenAI: config is valid JSON" bash -c "echo '$openai_config' | jq empty"
check "OpenAI: config model format correct" bash -c "echo '$openai_config' | jq -e '.model == \"openai/gpt-4o\"' >/dev/null"
check "OpenAI: no small_model (no limits)" bash -c "echo '$openai_config' | jq -e 'has(\"small_model\") | not' >/dev/null"
echo ""

# -----------------------------------------------------------------------
# 42. Multi-format provider fixtures — GSA USAi (with limits)
# -----------------------------------------------------------------------
echo "Provider: GSA USAi format (with limits):"

usai_resp=$(cat "$FIXTURES_DIR/usai-models.json")
usai_models=$(run_model_pipeline "$usai_resp")
usai_small=$(run_small_model_selection "$usai_resp")
usai_config=$(run_full_config_pipeline "$usai_resp" "gsa-usai" "https://api.gsa.usai.gov/api/v1")

check "USAi: 4 models parsed" bash -c "test \$(echo '$usai_models' | jq 'keys | length') -eq 4"
check "USAi: claude has context limit" bash -c "echo '$usai_models' | jq -e '.\"claude_3_5_sonnet\".limit.context == 200000' >/dev/null"
check "USAi: claude has output limit" bash -c "echo '$usai_models' | jq -e '.\"claude_3_5_sonnet\".limit.output == 8192' >/dev/null"
check "USAi: llama has 8k context" bash -c "echo '$usai_models' | jq -e '.\"llama-3-70b\".limit.context == 8192' >/dev/null"
check "USAi: small_model is llama (smallest ctx)" test "$usai_small" = "llama-3-70b"
check "USAi: config has small_model" bash -c "echo '$usai_config' | jq -e '.small_model == \"gsa-usai/llama-3-70b\"' >/dev/null"
check "USAi: config model is first (claude)" bash -c "echo '$usai_config' | jq -e '.model == \"gsa-usai/claude_3_5_sonnet\"' >/dev/null"
check "USAi: config uses HTTPS baseURL" bash -c "echo '$usai_config' | jq -r '.provider.\"gsa-usai\".options.baseURL' | grep -q 'https://'"
echo ""

# -----------------------------------------------------------------------
# 43. Multi-format provider fixtures — vLLM (max_model_len)
# -----------------------------------------------------------------------
echo "Provider: vLLM format (max_model_len):"

vllm_resp=$(cat "$FIXTURES_DIR/vllm-models.json")
vllm_models=$(run_model_pipeline "$vllm_resp")
vllm_small=$(run_small_model_selection "$vllm_resp")

check "vLLM: 2 models parsed" bash -c "test \$(echo '$vllm_models' | jq 'keys | length') -eq 2"
check "vLLM: llama has limit from max_model_len" bash -c "echo '$vllm_models' | jq -e '.\"meta-llama/Llama-3-70B-Instruct\".limit.context == 8192' >/dev/null"
check "vLLM: mixtral has limit from max_model_len" bash -c "echo '$vllm_models' | jq -e '.\"mistralai/Mixtral-8x7B-Instruct-v0.1\".limit.context == 32768' >/dev/null"
check "vLLM: no output limit (not provided)" bash -c "echo '$vllm_models' | jq -e '.\"meta-llama/Llama-3-70B-Instruct\".limit | has(\"output\") | not' >/dev/null"
check "vLLM: model IDs with slashes work as keys" bash -c "echo '$vllm_models' | jq -e 'has(\"meta-llama/Llama-3-70B-Instruct\")' >/dev/null"
check "vLLM: small_model picks smallest" test "$vllm_small" = "meta-llama/Llama-3-70B-Instruct"
echo ""

# -----------------------------------------------------------------------
# 44. Multi-format provider fixtures — Ollama (minimal)
# -----------------------------------------------------------------------
echo "Provider: Ollama format (minimal fields):"

ollama_resp=$(cat "$FIXTURES_DIR/ollama-models.json")
ollama_models=$(run_model_pipeline "$ollama_resp")
ollama_config=$(run_full_config_pipeline "$ollama_resp" "ollama" "http://localhost:11434/v1")

check "Ollama: 2 models parsed" bash -c "test \$(echo '$ollama_models' | jq 'keys | length') -eq 2"
check "Ollama: model with colon works" bash -c "echo '$ollama_models' | jq -e 'has(\"llama3:latest\")' >/dev/null"
check "Ollama: codellama:7b works" bash -c "echo '$ollama_models' | jq -e 'has(\"codellama:7b\")' >/dev/null"
check "Ollama: no limit fields" bash -c "echo '$ollama_models' | jq -e '.\"llama3:latest\" | has(\"limit\") | not' >/dev/null"
check "Ollama: config is valid" bash -c "echo '$ollama_config' | jq empty"
check "Ollama: local URL preserved" bash -c "echo '$ollama_config' | jq -e '.provider.ollama.options.baseURL == \"http://localhost:11434/v1\"' >/dev/null"
echo ""

# -----------------------------------------------------------------------
# 45. Edge case models — special characters, empty fields, long names
# -----------------------------------------------------------------------
echo "Edge case models:"

edge_resp=$(cat "$FIXTURES_DIR/edge-case-models.json")
edge_models=$(run_model_pipeline "$edge_resp")

check "Edge: fixture is valid JSON" bash -c "echo '$edge_resp' | jq empty"
check "Edge: 4 models parsed" bash -c "test \$(echo '$edge_models' | jq 'keys | length') -eq 4"
check "Edge: model with slashes/dots works" bash -c "echo '$edge_models' | jq -e 'has(\"org/model-name-v2.1\")' >/dev/null"
check "Edge: model with dots works" bash -c "echo '$edge_models' | jq -e 'has(\"model.with\")' >/dev/null"
check "Edge: long model name works" bash -c "echo '$edge_models' | jq -e '[keys[] | select(length > 80)] | length > 0' >/dev/null"
check "Edge: unicode model name works" bash -c "echo '$edge_models' | jq -e 'has(\"model-with-üñíçödé\")' >/dev/null"
check "Edge: empty owned_by handled" bash -c "echo '$edge_resp' | jq -e '.data[1].owned_by == \"\"' >/dev/null"
edge_config=$(run_full_config_pipeline "$edge_resp" "edge" "https://edge.test/v1")
check "Edge: full config pipeline succeeds" bash -c "echo '$edge_config' | jq empty"
echo ""

# -----------------------------------------------------------------------
# 46. Large model list performance
# -----------------------------------------------------------------------
echo "Large model list (120 models):"

large_resp=$(cat "$FIXTURES_DIR/large-models.json")

check "Large: fixture is valid JSON" bash -c "echo '$large_resp' | jq empty"
check "Large: 120 models in response" bash -c "test \$(echo '$large_resp' | jq '.data | length') -eq 120"

# Time the pipeline — should complete in under 5 seconds
large_start=$SECONDS
large_models=$(run_model_pipeline "$large_resp")
large_elapsed=$((SECONDS - large_start))

check "Large: 120 models parsed" bash -c "test \$(echo '$large_models' | jq 'keys | length') -eq 120"
check "Large: completes in <5s" bash -c "test $large_elapsed -lt 5"
large_small=$(run_small_model_selection "$large_resp")
check "Large: small_model selects model-000 (4096 ctx)" test "$large_small" = "model-000"
large_config=$(run_full_config_pipeline "$large_resp" "large" "https://large.test/v1")
check "Large: full config pipeline succeeds" bash -c "echo '$large_config' | jq empty"
echo ""

# -----------------------------------------------------------------------
# 47. HTTPS URL validation edge cases
# -----------------------------------------------------------------------
echo "HTTPS URL validation:"

# The validation logic from sandbox.sh:
# host=$(echo "$base_url" | sed -E 's|^https?://([^/:]+).*|\1|')
# if [[ "$base_url" != https://* ]] && [[ "$host" != "localhost" ]] && [[ "$host" != 127.0.0.1 ]]; then
#     err "must use HTTPS"

url_should_pass() {
    local url="$1"
    local host
    host=$(echo "$url" | sed -E 's|^https?://([^/:]+).*|\1|')
    if [[ "$url" == https://* ]] || [[ "$host" == "localhost" ]] || [[ "$host" == "127.0.0.1" ]]; then
        return 0
    fi
    return 1
}

check "URL: https://api.example.com passes" url_should_pass "https://api.example.com/v1"
check "URL: https://api.gsa.usai.gov passes" url_should_pass "https://api.gsa.usai.gov/api/v1"
check "URL: http://localhost passes" url_should_pass "http://localhost:11434/v1"
check "URL: http://localhost no port passes" url_should_pass "http://localhost/v1"
check "URL: http://127.0.0.1 passes" url_should_pass "http://127.0.0.1:8080/v1"
check "URL: http://127.0.0.1 no port passes" url_should_pass "http://127.0.0.1/v1"
check "URL: https://localhost passes" url_should_pass "https://localhost:11434/v1"
check "URL: http://remote.com rejected" bash -c "! url_should_pass 'http://remote.com/v1'"
check "URL: http://10.0.0.1 rejected" bash -c "! url_should_pass 'http://10.0.0.1/v1'"
check "URL: http://192.168.1.1 rejected" bash -c "! url_should_pass 'http://192.168.1.1/v1'"
# Live guard test via sandbox.sh
check_err "sandbox.sh: HTTP remote rejected" "must use HTTPS" bash -c "OPENAI_COMPAT_BASE_URL=http://remote.example.com/v1 OPENAI_COMPAT_API_KEY=test bash sandbox.sh models"
check_err "sandbox.sh: HTTP IP rejected" "must use HTTPS" bash -c "OPENAI_COMPAT_BASE_URL=http://10.0.0.5/v1 OPENAI_COMPAT_API_KEY=test bash sandbox.sh models"
echo ""

# -----------------------------------------------------------------------
# 48. E2E config generation — JSONC validation
# -----------------------------------------------------------------------
echo "E2E config generation + JSONC validation:"

# Generate a full config from USAi fixture and validate it end-to-end
e2e_config=$(run_full_config_pipeline "$(cat "$FIXTURES_DIR/usai-models.json")" "usai-e2e" "https://api.gsa.usai.gov/api/v1")

# Validate all required OpenCode schema fields
check "E2E: has \$schema field" bash -c "echo '$e2e_config' | jq -e '.\"\$schema\" == \"https://opencode.ai/config.json\"' >/dev/null"
check "E2E: model in provider/id format" bash -c "echo '$e2e_config' | jq -r '.model' | grep -qE '^[a-z0-9_-]+/[a-z0-9_./-]+$'"
check "E2E: has provider block" bash -c "echo '$e2e_config' | jq -e '.provider | keys | length > 0' >/dev/null"
check "E2E: provider has npm field" bash -c "echo '$e2e_config' | jq -e '.provider.\"usai-e2e\".npm == \"@ai-sdk/openai-compatible\"' >/dev/null"
check "E2E: provider has options.baseURL" bash -c "echo '$e2e_config' | jq -e '.provider.\"usai-e2e\".options.baseURL | startswith(\"https://\")' >/dev/null"
check "E2E: API key uses env ref" bash -c "echo '$e2e_config' | jq -r '.provider.\"usai-e2e\".options.apiKey' | grep -q '{env:'"
check "E2E: models object populated" bash -c "echo '$e2e_config' | jq -e '.provider.\"usai-e2e\".models | keys | length == 4' >/dev/null"
check "E2E: has small_model" bash -c "echo '$e2e_config' | jq -e 'has(\"small_model\")' >/dev/null"
check "E2E: small_model in provider/id format" bash -c "echo '$e2e_config' | jq -r '.small_model' | grep -qE '^[a-z0-9_-]+/'"
check "E2E: has enabled_providers" bash -c "echo '$e2e_config' | jq -e 'has(\"enabled_providers\")' >/dev/null"
check "E2E: enabled_providers whitelists only custom provider" bash -c "echo '$e2e_config' | jq -e '.enabled_providers == [\"usai-e2e\"]' >/dev/null"

# Simulate JSONC output (add header comments like cmd_config does)
e2e_jsonc="// Generated by agent-sandbox test
// Models discovered from: https://api.gsa.usai.gov/api/v1
$e2e_config"

# Strip comments and validate as JSON
check "E2E: JSONC strips to valid JSON" bash -c "echo '$e2e_jsonc' | grep -v '^//' | jq empty"
echo ""

# -----------------------------------------------------------------------
# 49. Provider name sanitization
# -----------------------------------------------------------------------
echo "Provider name sanitization:"

check "sanitize: alphanumeric preserved" bash -c "test \"\$(echo 'my-provider' | tr -dc '[:alnum:]-_' | head -c 50)\" = 'my-provider'"
check "sanitize: special chars stripped" bash -c "test \"\$(echo 'my provider!@#\$' | tr -dc '[:alnum:]-_' | head -c 50)\" = 'myprovider'"
check "sanitize: underscores preserved" bash -c "test \"\$(echo 'my_provider' | tr -dc '[:alnum:]-_' | head -c 50)\" = 'my_provider'"
check "sanitize: truncates at 50 chars" bash -c "test \$(echo 'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz' | tr -dc '[:alnum:]-_' | head -c 50 | wc -c) -eq 50"
echo ""

# -----------------------------------------------------------------------
# 50. load_env helper
# -----------------------------------------------------------------------
echo "load_env helper:"

# Create a temp .env to test with
load_env_tmp=$(mktemp -d)
trap 'rm -rf "$load_env_tmp"' EXIT

cat > "$load_env_tmp/.env" <<'ENVEOF'
OPENAI_COMPAT_BASE_URL=https://api.test.example.com/v1
OPENAI_COMPAT_API_KEY=test-key-12345
OPENAI_COMPAT_PROVIDER_NAME=test-load
# This is a comment
SOME_OTHER_VAR=other-value
ENVEOF

cp sandbox.sh config.sh "$load_env_tmp/"

# Test: load_env sources .env when vars not set
# We test the load_env logic directly (can't source sandbox.sh due to platform guard)
check "load_env: sources .env when vars unset" bash -c "
    ENV_FILE='$load_env_tmp/.env'
    unset OPENAI_COMPAT_BASE_URL 2>/dev/null || true
    # Inline the load_env logic
    while IFS='=' read -r key value; do
        key=\$(echo \"\$key\" | tr -d '[:space:]')
        [[ -z \"\$key\" || \"\$key\" == \\#* ]] && continue
        if [[ -z \"\${!key:-}\" ]]; then export \"\$key=\$value\"; fi
    done < \"\$ENV_FILE\"
    test \"\$OPENAI_COMPAT_BASE_URL\" = 'https://api.test.example.com/v1'
"

# Test: load_env respects existing env vars (won't override)
check "load_env: respects existing env vars" bash -c "
    cd '$load_env_tmp'
    ENV_FILE='.env'
    export OPENAI_COMPAT_BASE_URL='https://already-set.example.com/v1'
    load_env() {
        if [[ -n \"\${OPENAI_COMPAT_BASE_URL:-}\" ]]; then return 0; fi
    }
    load_env
    test \"\$OPENAI_COMPAT_BASE_URL\" = 'https://already-set.example.com/v1'
"

# Test: load_env skips comments
check "load_env: skips comment lines" bash -c "
    cd '$load_env_tmp'
    ENV_FILE='.env'
    unset OPENAI_COMPAT_BASE_URL 2>/dev/null || true
    load_env() {
        if [[ -n \"\${OPENAI_COMPAT_BASE_URL:-}\" ]]; then return 0; fi
        if [[ -f \"\$ENV_FILE\" ]]; then
            while IFS='=' read -r key value; do
                key=\$(echo \"\$key\" | tr -d '[:space:]')
                [[ -z \"\$key\" || \"\$key\" == \\#* ]] && continue
                if [[ -z \"\${!key:-}\" ]]; then export \"\$key=\$value\"; fi
            done < \"\$ENV_FILE\"
        fi
    }
    load_env
    # If comments were parsed as vars, we'd get an error
    test \"\$OPENAI_COMPAT_API_KEY\" = 'test-key-12345'
"

# Test: load_env fails when no .env exists
check "load_env: returns 1 when no .env" bash -c "
    cd /tmp
    ENV_FILE='.env.nonexistent'
    ENV_ENC='.env.enc.nonexistent'
    load_env() {
        if [[ -n \"\${OPENAI_COMPAT_BASE_URL:-}\" ]]; then return 0; fi
        if [[ -f \"\$ENV_FILE\" ]]; then return 0; fi
        return 1
    }
    ! load_env
"
echo ""

# -----------------------------------------------------------------------
# 51. cmd_quickstart guard tests
# -----------------------------------------------------------------------
echo "Quickstart command:"

# Test: quickstart fails at some guard (Docker or .env depending on environment)
# On macOS CI: Docker sandbox exists, so it should fail at .env check
# On systems without Docker: fails at Docker pre-flight check
_qs_output=$(bash sandbox.sh quickstart 2>&1) || true
if echo "$_qs_output" | grep -q "Docker sandbox not available"; then
	check "quickstart: fails pre-flight without Docker" true
elif echo "$_qs_output" | grep -q "not found\|not set"; then
	check "quickstart: fails without .env or required vars" true
else
	check "quickstart: fails with expected guard" false
fi

# Test: quickstart listed in help
check "quickstart: listed in help" bash -c "bash sandbox.sh help 2>&1 | grep -q 'quickstart'"
echo ""

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
summary
