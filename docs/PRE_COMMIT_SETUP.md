# Pre-commit Hooks Setup

This repository includes an optional pre-commit configuration that provides:
- Secret detection (via gitleaks)
- Basic file hygiene checks (trailing whitespace, end-of-file-fixer, YAML/JSON validation)

> [!NOTE]
> Pre-commit hooks are **opt-in** and do NOT auto-install during `make setup`.

---

## Why Optional?

Pre-commit hooks can interfere with user workflows, especially when:
- Users have their own pre-commit configurations
- Agents commit code on behalf of users
- Hooks require dependencies not available in all environments

By making hooks opt-in, users can:
- Learn from the example configuration
- Test pre-commit without commitment
- Decide if it fits their workflow

---

## Installing Pre-commit

### On Host Machine

```bash
# Install pre-commit
pip install pre-commit

# Install the hooks (from repo root)
pre-commit install

# Or use the make target
make install-hooks
```

### Inside Docker Sandbox (SBX)

If you're working inside a Docker Sandbox and want to use pre-commit:

```bash
# Install pre-commit (inside sandbox)
pip install pre-commit

# Install the hooks (from repo root)
pre-commit install

# Or use the make target (from repo root)
make install-hooks
```

---

## Running Checks Without Installing Hooks

You can run pre-commit checks on-demand without installing the hooks:

```bash
# Run all hooks on all files
pre-commit run --all-files

# Run all hooks on staged files only
pre-commit run

# Run a specific hook
pre-commit run gitleaks --all-files
```

This is useful for:
- Testing the configuration before installing hooks
- One-time checks before pushing
- CI/CD validation without hook installation

---

## Using Pre-commit with OpenCode

If you're using OpenCode inside SBX, the agent can run pre-commit checks on your behalf:

```bash
# After creating a sandbox and installing pre-commit
sbx exec SANDBOX_NAME pre-commit run --all-files
```

The agent should be configured to run pre-commit checks before committing if hooks are installed. If hooks are not installed, the agent will commit normally.

---

## Configuration Details

The `.pre-commit-config.yaml` file uses SHA-pinned revisions for security:

- **pre-commit-hooks v6.0.0**: Basic file hygiene
- **gitleaks v8.24.3**: Secret detection

To update hook versions, edit `.pre-commit-config.yaml` and update both the rev (SHA) and the version comment.

---

## Troubleshooting

### "pre-commit: command not found"

Install pre-commit first:
```bash
pip install pre-commit
```

### Hooks failing on existing files

Pre-commit may flag issues in existing files. Fix them or use:
```bash
# Run once to auto-fix what can be fixed
pre-commit run --all-files

# Then stage the fixes
git add -u
```

### Gitleaks false positives

If gitleaks detects a false positive, add it to `.gitleaksignore`:
```bash
echo "path/to/file:line-number" >> .gitleaksignore
```

---

## Next Steps

- [sbx CLI Quickstart](QUICKSTART_SBX.md) — Main setup guide
- [Known Failure Modes](KNOWN_FAILURE_MODES.md) — Common issues and solutions
