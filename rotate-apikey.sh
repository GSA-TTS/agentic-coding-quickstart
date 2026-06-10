#!/usr/bin/env bash
# Script to rotate ur keyz

set -euo pipefail

fail() {
    echo "$@" >&2
    exit 1
}

# Grab the placeholder
placeholder=$(sbx secret ls -g | grep '\sUSAI_API_KEY\s' | awk '{print $4}')

if [ -z "$placeholder" ]; then
   fail "Error: USAI_API_KEY not found. Run 'sbx secret ls -g' to check."
fi

# Rotate the secret with your new key (will prompt for input)
# use `exec` so sbx is wholly responsible for error handling and input
exec sbx secret set-custom -g --host api.gsa.usai.gov \
      --env USAI_API_KEY --placeholder "$placeholder"
