#!/usr/bin/env bash
# Script to initialize a new project from the agentic-coding-quickstart

# --- Configuration ---
# Get the directory of this script (portable for Linux and macOS)
QUICKSTART_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" )" > /dev/null 2>&1 && pwd )"

# --- Functions ---
function show_usage() {
    echo "Usage: $0 /path/to/your/new-project"
    echo "Initializes a new project directory with bootstrapping files from the quickstart repo."
    exit 1
}

# --- Main Logic ---
# Check if a target directory was provided
if [ -z "$1" ]; then
    echo "ERROR: No target directory specified."
    show_usage
fi

TARGET_DIR="$1"

# Run the make command from the quickstart directory
echo "Changing to quickstart directory: $QUICKSTART_DIR"
cd "$QUICKSTART_DIR" || { echo "ERROR: Could not navigate to the quickstart directory."; exit 1; }

echo "Initializing project in: $TARGET_DIR"
make init-project TARGET_DIR="$TARGET_DIR"
