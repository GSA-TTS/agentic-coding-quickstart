#!/usr/bin/env bash
# Script to initialize/bootstrap a project from the agentic-coding-quickstart

set -e

# --- Configuration ---
# Get the directory of this script (portable for Linux and macOS)
QUICKSTART_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" > /dev/null 2>&1 && pwd )"

# --- Functions ---
show_usage() {
    echo "Usage: $0 [OPTIONS] /path/to/project"
    echo ""
    echo "Bootstrap a new or existing project directory with agentic-coding configuration."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit"
    echo ""
    echo "What gets provisioned:"
    echo "  - AGENTS.md        Behavioral rules for AI agents"
    echo "  - opencode.jsonc   Pre-configured USAi endpoints"
    echo "  - Makefile         Helper commands (make setup, make doctor, etc.)"
    echo "  - .zed/tasks.json  Zed Editor task integration"
    echo "  - README.md        Generated project README (only if it doesn't exist)"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/new-project      # Create and bootstrap a new directory"
    echo "  $0 /path/to/existing-app     # Bootstrap an existing directory"
    echo ""
    echo "The script is idempotent - safe to run multiple times on the same directory."
}

# --- Argument Parsing ---
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

# --- Main Logic ---
# Check if a target directory was provided
if [ -z "$1" ]; then
    echo "ERROR: No target directory specified."
    echo ""
    show_usage
    exit 1
fi

TARGET_DIR="$1"

# Run the make command from the quickstart directory
echo "Changing to quickstart directory: $QUICKSTART_DIR"
cd "$QUICKSTART_DIR" || { echo "ERROR: Could not navigate to the quickstart directory."; exit 1; }

echo "Initializing project in: $TARGET_DIR"
make init-project TARGET_DIR="$TARGET_DIR"
