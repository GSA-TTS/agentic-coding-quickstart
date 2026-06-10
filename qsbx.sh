#!/bin/bash
#
# qsbx — sbx wrapper that mounts a shared "quickstart" config clone into new sandboxes
#
# Problem: `sbx create` makes each sandbox fresh, with no access to your
# persistent global config (agent settings, AGENTS.md, skills, etc.). Without
# this, you end up copying those files into every new sandbox and manually
# keeping them in sync.
#
# Solution: on `sbx create`, qsbx
#   1. mounts $QUICKSTART_CLONE as an extra read-write workspace, and
#   2. sets OPENCODE_CONFIG_DIR to it in the sandbox's persistent environment,
# so the agent can find — and edit — your global config in one shared place.
# All other subcommands pass straight through to sbx.
#
# Setup:  export QUICKSTART_CLONE=/path/to/my/quickstart-clone
#
# Workflow:
#   git switch -c "$(whoami)-global-config"   # personal branch for your config
#   qsbx create opencode .                    # new sandbox, clone mounted RW
#   # ...customize AGENTS.md, skills, etc. inside the sandbox...
#   git fetch origin main && git merge origin/main   # pull in upstream changes

set -euo pipefail

: "${QUICKSTART_CLONE:?Set QUICKSTART_CLONE before running this script}"

PERSIST_FILE="/etc/sandbox-persistent.sh"

if [ "${1:-}" = "create" ]; then
  # --- 1. Create the sandbox, appending the clone as an extra workspace PATH.
  #     We need create's stdout for parsing, but also want the user to see it.
  #     If a terminal is attached, tee to /dev/tty (keeps stdout pristine);
  #     otherwise (headless/CI), skip the tee and just capture.
  #     The "Created sandbox" line is on stdout (verified).
  if [ -t 1 ]; then
    create_output=$(sbx "$@" "$QUICKSTART_CLONE" | tee /dev/tty)
  else
    create_output=$(sbx "$@" "$QUICKSTART_CLONE")
  fi

  # --- 2. Extract the sandbox name from the "✓ Created sandbox 'NAME'" line.
  sandbox_name=$(
    printf '%s\n' "$create_output" \
      | sed -n "s/.*Created sandbox '\([^']*\)'.*/\1/p" \
      | head -n1
  )

  if [ -z "$sandbox_name" ]; then
    echo "error: could not determine sandbox name from 'sbx create' output" >&2
    exit 1
  fi

  # --- 3. Write OPENCODE_CONFIG_DIR into the new sandbox's persistent file.
  sbx exec \
    -e QUICKSTART_CLONE="$QUICKSTART_CLONE" \
    -e PERSIST_FILE="$PERSIST_FILE" \
    "$sandbox_name" \
    bash <<'EOF'
config_value="export OPENCODE_CONFIG_DIR='$QUICKSTART_CLONE'"

# ':' is the no-op builtin (does nothing, exits 0); with '>' it creates an
# empty file without an external command, only when the file is missing.
[ -f "$PERSIST_FILE" ] || : > "$PERSIST_FILE"

if grep -qE '^[[:space:]]*export OPENCODE_CONFIG_DIR=' "$PERSIST_FILE"; then
  # Substitute in place, preserving captured leading whitespace (\1).
  # Escape '&' and '|' for sed's replacement side (given the '|' delimiter).
  escaped=$(printf '%s' "$config_value" | sed -e 's/[&|]/\\&/g')
  sed -i -E "s|^([[:space:]]*)export OPENCODE_CONFIG_DIR=.*|\1$escaped|" "$PERSIST_FILE"
else
  printf '%s\n' "$config_value" >> "$PERSIST_FILE"
fi
EOF

else
  # --- Any other subcommand: pass through unmolested ---
  sbx "$@"
fi
