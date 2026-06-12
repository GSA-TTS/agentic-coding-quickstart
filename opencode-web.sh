#!/bin/bash
# This runs OpenCode Web in a Docker Sandbox using the sbx CLI and then
# publishes it to your host on port 4096.
# Usage: opencode-web [your sandbox name]
# Connect via http://127.0.0.1:4096
# To stop: sbx stop [your sandbox name]

sandbox="${1:?Usage: $0 <sandbox-name>}"

# Run the sandbox detached with opencode web
sbx exec -d "$sandbox" sh -lc 'nohup opencode web --hostname 0.0.0.0 --port 4096' &

# Poll + publish ports
until sbx ports "$sandbox" --publish 4096:4096 2>/dev/null; do sleep 1; done
echo "Ready: $sandbox on port 4096"
