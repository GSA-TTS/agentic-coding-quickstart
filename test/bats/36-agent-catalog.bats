#!/usr/bin/env bats
#
# 36-agent-catalog.bats — shared agent catalog parity checks
#
# shellcheck shell=bats

setup() { acq_setup_stubs; }
teardown() { acq_teardown_stubs; }

load 'helper'

@test "agents: shared catalog exposes supported tokens" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/agents.sh"; acq_known_agents'
  assert_success
  assert_output $'claude\ncodex\ncopilot\ncursor\ndocker-agent\ndroid\ngemini\nkiro\nopencode\nshell'
}

@test "agents: sbx and msb dispatch use the shared catalog" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/common.sh"
    . "'"$REPO_ROOT"'/acq.backends/sbx.sh"
    for agent in $(acq_known_agents); do is_known_agent "$agent" || exit 1; done
    if is_known_agent notanagent; then exit 2; fi
    . "'"$REPO_ROOT"'/acq.backends/msb.sh"
    for agent in $(acq_known_agents); do is_known_agent "$agent" || exit 3; done
    if is_known_agent notanagent; then exit 4; fi
    exit 0
  '
  assert_success
}

@test "agents: template image naming follows sandbox-template convention" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/agents.sh"
    acq_agent_template_image opencode
    acq_agent_template_image shell
  '
  assert_success
  assert_output $'docker.io/docker/sandbox-templates:opencode-docker\ndocker.io/docker/sandbox-templates:shell-docker'
}

@test "agents: claude and cursor map to their real product template tags" {
  # Docker Hub ships these two under longer product names than the short acq
  # token; a naive <token>-docker would 404. Verified live: claude-docker and
  # cursor-docker 404; claude-code-docker and cursor-agent-docker 200.
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/agents.sh"
    acq_agent_template_image claude
    acq_agent_template_image cursor
  '
  assert_success
  assert_output $'docker.io/docker/sandbox-templates:claude-code-docker\ndocker.io/docker/sandbox-templates:cursor-agent-docker'
}

@test "agents: every known agent derives a template image with a safe tag" {
  run bash -c '
    . "'"$REPO_ROOT"'/acq.backends/agents.sh"
    rc=0
    for agent in $(acq_known_agents); do
      img=$(acq_agent_template_image "$agent") || { echo "no image for $agent"; rc=1; continue; }
      case "$img" in
        docker.io/docker/sandbox-templates:*-docker) ;;
        *) echo "unexpected image for $agent: $img"; rc=1 ;;
      esac
    done
    exit "$rc"
  '
  assert_success
}

@test "agents: known agent list is defined only in the shared catalog" {
  run bash -c '
    hits=$(grep -lE "^[[:space:]]*(ACQ_)?KNOWN_AGENTS=" \
      "'"$REPO_ROOT"'/acq.backends/sbx.sh" \
      "'"$REPO_ROOT"'/acq.backends/msb.sh" 2>/dev/null || true)
    [ -z "$hits" ]
  '
  assert_success
}

@test "agents: prime-agent is intentionally not supported by this change" {
  run bash -c '. "'"$REPO_ROOT"'/acq.backends/agents.sh"; acq_is_known_agent prime-agent'
  assert_failure
}
