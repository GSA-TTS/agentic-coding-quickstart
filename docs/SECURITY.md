# Security Model

## Threat Model

Agent Sandbox isolates AI coding agents from your host system and local network while allowing controlled internet access for package installation and API calls.

**Platform:** macOS only. Relies on macOS Keychain for secret storage and Docker Desktop for sandbox isolation.

### What We Protect Against

| Threat | Mitigation |
|--------|------------|
| Agent accesses LAN resources | RFC 1918 CIDR blocks via `docker sandbox network proxy` |
| Agent steals cloud credentials via IMDS | Block 169.254.169.254 (AWS/GCP) and 168.63.129.16 (Azure) |
| Secrets leaked to disk | SOPS decrypts to temp file (mode 600, auto-deleted on exit); plaintext .env deleted after encryption |
| Secrets stolen from environment | Docker sandbox isolation; env vars scoped to sandbox exec session |
| Agent persists across sessions | `make clean` removes all sandbox state |

### Partial Mitigations

| Threat | Status | Notes |
|--------|--------|-------|
| Agent modifies project files | **Workspace is writable by design.** The mounted `REPO` directory is read-write so the agent can edit code. For read-only access, use `docker sandbox run opencode ~/project ~/extra:ro` directly (extra workspaces support `:ro` suffix). |
| Resource exhaustion (CPU/memory/disk) | Docker Desktop sandbox microVMs have default resource limits inherited from Docker Desktop settings (CPU cores, memory cap). Check Docker Desktop > Settings > Resources to view and adjust limits. |
| IPv6 bypass | Network policy blocks both IPv4 and IPv6 CIDRs (ULA, link-local, loopback, AWS IPv6 IMDS). Both are applied via `docker sandbox network proxy --block-cidr`. |

### What We Don't Protect Against

- **Malicious internet exfiltration**: The agent has internet access and your API keys. It could send data to external services. This is an inherent trade-off — agents need internet to install packages and call APIs.
- **Docker Desktop vulnerabilities**: We rely on Docker's sandbox isolation. A Docker escape would bypass our controls.
- **macOS Keychain compromise**: If an attacker has access to your macOS session, they can read the AGE key from Keychain.
- **Supply chain attacks**: Packages installed by the agent inside the sandbox are not verified. A malicious dependency could exfiltrate data.

## Network Policy

Defined in `network-policy.json`. Applied via `docker sandbox network proxy`. Default policy is **allow with explicit blocks**:

| CIDR | Purpose |
|------|---------|
| `10.0.0.0/8` | RFC 1918 — private network |
| `172.16.0.0/12` | RFC 1918 — private network |
| `192.168.0.0/16` | RFC 1918 — private network |
| `169.254.0.0/16` | IPv4 link-local (covers AWS/GCP IMDS at 169.254.169.254) |
| `168.63.129.16/32` | Azure instance metadata |
| `100.100.100.200/32` | Alibaba Cloud instance metadata |
| `fc00::/7` | IPv6 ULA (private equivalent) |
| `fe80::/10` | IPv6 link-local |
| `::1/128` | IPv6 loopback |
| `fd00:ec2::254/128` | AWS IPv6 IMDS endpoint |

## Audit Logging

All sandbox operations are logged to `~/.config/agent-sandbox/audit.log`:

```
2026-02-24T14:00:00-05:00	setup	completed
2026-02-24T14:01:00-05:00	run:start	repo=/Users/you/project
2026-02-24T14:30:00-05:00	run:stop	repo=/Users/you/project
2026-02-24T14:30:01-05:00	clean	sandbox removed
```

### Reviewing Audit Logs

```bash
# View recent entries
tail -20 ~/.config/agent-sandbox/audit.log

# Find all sessions for a specific project
grep "repo=/Users/you/project" ~/.config/agent-sandbox/audit.log

# Check for sessions without clean stop (possible crash or kill)
grep "run:start" ~/.config/agent-sandbox/audit.log | while read -r line; do
    ts=$(echo "$line" | cut -f1)
    grep -q "run:stop.*$ts" ~/.config/agent-sandbox/audit.log || echo "Missing stop: $line"
done
```

**Suspicious patterns to look for:**
- Sessions without corresponding `run:stop` entries (agent crash or force kill)
- Very long sessions (agent running unattended)
- Multiple rapid `encrypt`/`decrypt` cycles (possible key extraction attempt)

**Log rotation:** The audit log grows unbounded. Rotate periodically:
```bash
# Keep last 1000 entries
tail -1000 ~/.config/agent-sandbox/audit.log > ~/.config/agent-sandbox/audit.log.tmp
mv ~/.config/agent-sandbox/audit.log.tmp ~/.config/agent-sandbox/audit.log
```

## Secret Lifecycle

```
1. User fills .env          (plaintext, local only)
2. make encrypt             (SOPS/AGE → .env.enc, .env deleted)
3. make run                 (Keychain → decrypt to temp file → --env-file → sandbox exec)
4. Sandbox exits            (env vars gone, temp file cleaned up via trap)
```

Secrets are decrypted to a temp file via `mktemp` (using `$TMPDIR` or `/tmp`), created with `umask 077` (mode 600) and automatic cleanup on exit via `trap`. The file is passed to `docker sandbox exec --env-file` and deleted when the session ends or the process receives a signal (EXIT, INT, TERM, HUP, QUIT, PIPE).

## Recommendations

1. **Rotate API keys regularly** — treat sandbox-injected keys as potentially exposed
2. **Use scoped API keys** — create keys with minimum required permissions
3. **Review audit logs** — check `~/.config/agent-sandbox/audit.log` periodically
4. **Lock your Mac** — Keychain access requires an active macOS session. If locked, sandbox.sh will fail early with a clear error message
5. **Mount read-only when possible** — use `docker sandbox run opencode ~/project ~/extra-dir:ro` directly for read-only extra workspaces
6. **Check Docker Desktop resource limits** — Settings > Resources > adjust CPU/memory caps
7. **PIV/CAC not needed** — Hardware tokens (YubiKey/smart cards) were evaluated and rejected. AGE+Keychain is sufficient for single-developer local use. Revisit if multi-user or compliance requirements emerge
