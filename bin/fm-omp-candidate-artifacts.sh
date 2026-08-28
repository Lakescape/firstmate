#!/usr/bin/env bash
# Render the inert OMP review artifact.
# Usage: fm-omp-candidate-artifacts.sh requested-manifest
#
# The requested manifest is static review material, not a launch contract.
# This script accepts no executable, file descriptor, path, model, extension,
# provider, or command input and invokes no external command.
# It does not create configuration, lifecycle, or state artifacts.
set -u

usage() {
  printf '%s\n' 'usage: fm-omp-candidate-artifacts.sh requested-manifest' >&2
  exit 2
}

case "${1:-}" in
  requested-manifest)
    [ "$#" -eq 1 ] || usage
    printf '%s\n' '{"artifactStatus":"inert-non-dispatchable","dispatchable":false,"effectiveBehaviorProven":false,"requestedEnvironment":{"unset":["CLAUDECODE","PI_CODING_AGENT","PI_CONFIG_FILES","OMP_PROFILE","PI_PROFILE","GROK_AGENT","FM_PI_HARNESS","CURSOR_AGENT","CURSOR_INVOKED_AS","TRACEPARENT"],"set":{"PI_CODING_AGENT_DIR":"<isolated-agent-directory>"}},"requestedSettings":{"retry":{"modelFallback":false,"usageAwareFallback":false,"fallbackChains":{}},"astEdit":{"enabled":false}},"requestedArgv":["<unresolved-omp-executable>","--cwd","<isolated-empty-cwd>","--add-dir","<task-worktree>","--approval-mode","yolo","--no-title","--no-extensions","--no-skills","--no-lsp","--no-tools","--model","<explicit-provider/model>","-e","<firstmate-lifecycle-extension>"],"followUpRequired":["executable provenance and activation authority","session-free effective configuration and tool containment","First Mate interrupt exit and relaunch control"]}'
    ;;
  *) usage ;;
esac
