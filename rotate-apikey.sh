#!/usr/bin/env bash
# Script to rotate ur keyz

set -euo pipefail

QS_SBX="opencode-agentic-coding-quickstart"

fail() {
    echo "$@" >&2
    exit 1
}

# Grab the placeholder
placeholder=$(sbx secret ls -g | grep -E '[[:space:]]USAI_API_KEY[[:space:]]' | awk '{print $4}')

if [ -z "$placeholder" ]; then
   fail "Error: USAI_API_KEY not found. Run 'sbx secret ls -g' to check."
fi

# Rotate the secret with your new key (will prompt for input)
sbx secret set-custom -g --host api.gsa.usai.gov \
      --env USAI_API_KEY --placeholder "$placeholder"

if sbx ls | grep -qE "^${QS_SBX}[[:space:]]"; then
  echo "Validating new key. 200 is OK, otherwise, you have a problem"
  sbx exec "$QS_SBX" -- sh -c \
     'curl -sS -o /dev/null -w "%{http_code}\n" \
      -H "Authorization: Bearer $USAI_API_KEY" \
      https://api.gsa.usai.gov/api/v1/models'
else
  echo "Cannot find sandbox, $QS_SBX, for validation. See README.md for help"
fi
