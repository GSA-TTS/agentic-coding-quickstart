# SOPS/AGE Secret Management

## Overview

Agent Sandbox uses [SOPS](https://github.com/getsops/sops) with [AGE](https://github.com/FiloSottile/age) encryption to manage secrets. The private key lives in macOS Keychain (never on disk), and secrets are decrypted to a temporary file at runtime (mode 600, auto-deleted on exit).

## How It Works

```
Setup:  age-keygen → private key → macOS Keychain
                   → public key  → .sops.yaml (committed)

Encrypt: .env → sops encrypt → .env.enc (local, gitignored)
                              → .env deleted

Run:    Keychain → private key → sops decrypt to temp file → docker sandbox exec --env-file
```

## Key Storage

The AGE private key is stored in macOS Keychain under:
- **Service:** `sops-age-key` (defined as `DEFAULT_KEYCHAIN_SERVICE` in `config.sh`)
- **Account:** your macOS username

To view:
```bash
security find-generic-password -a "$USER" -s sops-age-key -w
```

To remove (if rotating keys):
```bash
security delete-generic-password -a "$USER" -s sops-age-key
```

**Important:** The Keychain is protected by your macOS login password. If someone has access to your unlocked Mac session, they can read the key. Always lock your screen when stepping away.

**If the Keychain is locked** (e.g., after screen lock timeout), sandbox.sh will fail with a clear error. Unlock with:
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

## File Roles

| File | Committed | Contents |
|------|-----------|----------|
| `.sops.yaml` | Yes | AGE public key (safe to share) |
| `.env.example` | Yes | Template with empty values |
| `.env` | No | Plaintext secrets (temporary, deleted after encrypt) |
| `.env.enc` | No | Encrypted secrets |

## Manual SOPS Operations

```bash
# Encrypt (.env → .env.enc)
export SOPS_AGE_KEY="$(security find-generic-password -a "$USER" -s sops-age-key -w)"
sops encrypt --input-type dotenv --output-type dotenv .env > .env.enc

# Decrypt (.env.enc → .env)
sops decrypt --input-type dotenv --output-type dotenv .env.enc > .env
unset SOPS_AGE_KEY

# Edit in-place (decrypts, opens editor, re-encrypts)
sops --input-type dotenv --output-type dotenv .env.enc
```

**Note:** The `--input-type dotenv --output-type dotenv` flags are required because SOPS does not auto-detect the `.env.enc` extension as dotenv format. Without these flags, SOPS defaults to JSON parsing and fails.

## Team Sharing

To share encrypted secrets with a teammate:

1. Get their AGE public key (starts with `age1...`)
2. Add it to `.sops.yaml` as a comma-separated list:
   ```yaml
   creation_rules:
     - age: "age1your_key_here,age1teammate_key_here"
   ```
   SOPS AGE recipients are comma-separated in a single string.
3. Re-encrypt with updated recipients: `sops updatekeys .env.enc`

**Note:** When adding teammates, they must share their public key with you. The private key never leaves their machine.

## Key Rotation

```bash
# 1. Delete old key from Keychain
security delete-generic-password -a "$USER" -s sops-age-key

# 2. Generate new key
make setup

# 3. Re-encrypt secrets with new key
make decrypt
make encrypt
```

**For teams:** After rotating your key, share your new public key with teammates so they can update `.sops.yaml` and re-encrypt.

## Backup

If you lose access to your Keychain (hardware failure, OS reinstall), you lose the ability to decrypt `.env.enc`. Mitigations:

- **Re-create secrets manually** from your API provider dashboards (recommended)
- **Export the key** to a secure backup: `security find-generic-password -a "$USER" -s sops-age-key -w > ~/age-key-backup.txt` — store this file in a secure location (password manager, encrypted USB) and delete it from disk immediately

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `no matching keys found` | Key mismatch. Run `make setup` to regenerate |
| `Keychain access denied` | Allow access in macOS Security preferences |
| Can't decrypt teammate's file | Ask them to add your public key to `.sops.yaml` |
| `.sops.yaml has placeholder key` | Run `make setup` — the placeholder was not replaced |
