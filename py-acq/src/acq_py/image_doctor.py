"""Guest image diagnostics, matching the ADR-0030 Bash probe."""

SCRIPT = r'''
ACQ_ADR0030_IMAGE_DIAGNOSTIC=1
warns=0
ok() { printf '  ok: %s\n' "$1"; }
warn() {
  warns=$((warns + 1))
  printf '  warning: %s\n' "$1"
  printf '           fix: %s\n' "$2"
}

if [ "${HOME:-}" = "/home/agent" ]; then
  ok "HOME is /home/agent"
else
  warn "HOME is ${HOME:-unset}, not /home/agent" "run diagnostics as the agent user with HOME=/home/agent"
fi

if [ "$(id -un 2>/dev/null || true)" = "agent" ]; then
  ok "running as agent user"
else
  warn "diagnostic is not running as the agent user" "run sandbox diagnostics as the unprivileged agent user"
fi

if [ -d /nix ]; then
  ok "/nix exists"
  if [ -w /nix 2>/dev/null ]; then
    ok "/nix is writable"
  else
    warn "/nix is not writable" "mount or bake a writable Nix store at /nix for devenv/cache reuse"
  fi
else
  warn "/nix is missing" "use a devenv-capable image with its Nix store at /nix"
fi

for tool in nix devenv direnv; do
  if command -v "$tool" >/dev/null 2>&1; then
    ver=$($tool --version 2>/dev/null | head -n1 || true)
    if [ -n "$ver" ]; then
      ok "$tool is on PATH ($ver)"
    else
      ok "$tool is on PATH"
    fi
  else
    warn "$tool is not on PATH" "install $tool in the base image or a create-time kit"
  fi
done

if [ -w /home/agent ]; then
  ok "/home/agent is writable"
else
  warn "/home/agent is not writable" "make /home/agent owned/writable by the agent user"
fi

if command -v sudo >/dev/null 2>&1; then
  # Best-effort privilege probe: sudo -n may update guest-local sudo/audit state.
  if sudo -n true >/dev/null 2>&1; then
    ok "passwordless sudo probe works"
  else
    warn "sudo exists but passwordless sudo probe failed" "grant NOPASSWD sudo for declared privileged kit steps"
  fi
else
  warn "sudo is not on PATH" "install sudo and allow passwordless sudo where privileged kit features are needed"
fi

home=${HOME:-/home/agent}
if [ -d "$home/.rc.d" ]; then
  ok "~/.rc.d exists"
else
  warn "~/.rc.d is missing" "install the neutral shell hook directory at /home/agent/.rc.d"
fi

hook=0
for profile in "$home/.profile" "$home/.bashrc" "$home/.zshrc" /etc/profile /etc/bash.bashrc /etc/profile.d/acq*.sh; do
  # Match either an explicit `source/.  …rc.d…` line OR acq's own login bridge
  # marker (acq-login-profile), whose loop sources ~/.rc.d indirectly through a
  # variable — so a plain `source .rc.d` grep alone would miss it. See ADR-0030.
  if [ -f "$profile" ] \
      && grep -Eq '(^|[[:space:]])(source|\.)[[:space:]].*\.rc\.d|acq-login-profile' "$profile" 2>/dev/null; then
    hook=1
    break
  fi
done
if [ "$hook" -eq 1 ]; then
  ok "shell startup references ~/.rc.d"
else
  warn "no shell startup hook for ~/.rc.d found" "source ~/.rc.d snippets from shell startup in deterministic order"
fi

printf '  summary: %s warning(s); diagnostics only, create/run are not blocked\n' "$warns"
exit 0
'''


def stub_output(missing: bool = False) -> str:
    """Deterministic guest capabilities for the bundled offline backend seams."""
    messages = [
        "HOME is /home/agent", "running as agent user", "/nix exists", "/nix is writable",
        "nix is on PATH", "devenv is on PATH", "direnv is on PATH",
        "/home/agent is writable", "passwordless sudo probe works", "~/.rc.d exists",
        "shell startup references ~/.rc.d",
    ]
    lines = ["  ok: " + message for message in messages
             if not missing or message not in ("devenv is on PATH", "shell startup references ~/.rc.d")]
    if missing:
        lines += ["  warning: devenv is not on PATH",
                  "           fix: install devenv in the base image or a create-time kit",
                  "  warning: no shell startup hook for ~/.rc.d found",
                  "           fix: source ~/.rc.d snippets from shell startup in deterministic order"]
    lines.append(f"  summary: {2 if missing else 0} warning(s); diagnostics only, create/run are not blocked")
    return "\n".join(lines) + "\n"
