#!/bin/bash
set -euo pipefail

# This runs OpenCode Web in a Docker Sandbox using the sbx CLI.
# Port 4096 must already be published on the sandbox (one-time setup;
# see the note at the bottom of this file).
# Usage: opencode-web <your sandbox name>
# Connect via http://127.0.0.1:4096
# To stop: sbx stop <your sandbox name>

sandbox="${1:?Usage: $0 <sandbox-name>}"

# Run the sandbox detached with opencode serve
sbx exec -d "$sandbox" sh -lc 'nohup opencode serve --hostname 0.0.0.0 --port 4096 >/dev/null 2>&1' >/dev/null 2>&1 &

echo "OpenCode server started."
echo
# One-time setup: if you haven't already published port 4096 on this sandbox,
# run the command printed below once (it is a persistent setting on the sandbox).
echo "If you haven't already published port 4096 on this sandbox, run this once:"
echo "  sbx ports $sandbox --publish 4096:4096"
echo
echo "Then connect via: http://127.0.0.1:4096"
