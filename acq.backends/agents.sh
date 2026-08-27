#!/bin/bash
#
# acq.backends/agents.sh — shared agent catalog for acq backends
#
# This is the single source of truth for agent tokens accepted by acq dispatch.
# Keep backend-specific behavior (installation recipes, attach mechanics) in the
# adapters, but keep the token list and template naming convention here so sbx
# and msb cannot drift.

# Space-padded for simple shell membership checks.
# shellcheck disable=SC2034
ACQ_KNOWN_AGENTS=" claude codex copilot cursor docker-agent droid gemini kiro opencode shell "

acq_known_agents() {
  printf '%s\n' claude codex copilot cursor docker-agent droid gemini kiro opencode shell
}

acq_is_known_agent() {
  case "$ACQ_KNOWN_AGENTS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

acq_agent_safe_token() {
  case "$1" in
    ""|*[!a-z-]*) return 1 ;;
    *) return 0 ;;
  esac
}

acq_agent_template_image() {
  local agent="${1:-shell}"
  case "$agent" in
    shell) printf '%s\n' "docker.io/docker/sandbox-templates:shell-docker" ;;
    *)
      acq_is_known_agent "$agent" || return 1
      acq_agent_safe_token "$agent" || return 1
      printf 'docker.io/docker/sandbox-templates:%s-docker\n' "$agent"
      ;;
  esac
}

acq_agent_has_msb_install_recipe() {
  case "$1" in
    opencode) return 0 ;;
    *) return 1 ;;
  esac
}
