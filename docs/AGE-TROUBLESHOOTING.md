# AGE Key Troubleshooting Guide

This guide helps resolve issues with AGE key management in agent-sandbox.

## Common Issues and Solutions

### 1. .sops.yaml Has Placeholder Key

**Symptoms**: 
- Error: "FAIL: .sops.yaml has placeholder key (run 'make setup')"
- Running `make setup` doesn't fix the issue

**Solution**:
```bash
# Use the reset-keys command to regenerate keys and fix sync issues
make reset-keys
```

### 2. Cannot Decrypt .env.enc

**Symptoms**:
- Error when running `make decrypt`
- Error message about invalid key or decryption failure

**Solution**:
```bash
# The reset-keys tool will attempt to decrypt with the current key
# If successful, it will create a backup and regenerate keys
make reset-keys
```

### 3. Key Rotation

**When to rotate keys**:
- Security policy requires regular key rotation
- You suspect key compromise
- You're having persistent issues with encryption/decryption

**How to rotate keys**:
```bash
# This will backup your current files, generate new keys, and re-encrypt
make reset-keys
```

## Understanding the AGE Key System

The agent-sandbox uses three components for secret management:

1. **AGE private key**: Stored in macOS Keychain (never written to disk)
2. **AGE public key**: Stored in `.sops.yaml` (safe to commit to git)
3. **Encrypted .env.enc**: Contains your encrypted API keys

When these components get out of sync, you may experience issues. The `reset-keys.sh` script fixes these by:

1. Creating backups of critical files
2. Decrypting .env.enc if possible
3. Removing the old key from Keychain
4. Generating a new key pair
5. Updating .sops.yaml with the new public key
6. Re-encrypting .env with the new key

## Best Practices

1. **Regular backups**: The `reset-keys.sh` script automatically creates timestamped backups
2. **Validate after key changes**: Run `make validate` after key operations
3. **Test decryption**: Run `make decrypt` followed by `make encrypt` to verify round-trip works

## Team Key Sharing

For sharing keys with team members, provide them with:
1. The encrypted .env.enc file
2. The AGE private key (via secure channel)

They can then store the key in their Keychain using:
```bash
security add-generic-password -a "$USER" -s "sops-age-key" -w "YOUR-AGE-SECRET-KEY" -T /usr/bin/security -U
```

For more detailed SOPS/AGE documentation, see `docs/SOPS-SETUP.md`.