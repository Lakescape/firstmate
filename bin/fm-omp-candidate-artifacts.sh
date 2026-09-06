#!/usr/bin/env bash
# Render the dormant OMP candidate's isolated settings and launch artifacts.
# Usage:
#   fm-omp-candidate-artifacts.sh prepare <agent-dir> <cwd>
#   fm-omp-candidate-artifacts.sh manifest <agent-dir> <cwd> <binary> <model> <extension>
#   fm-omp-candidate-artifacts.sh verify-boundary <manifest> <containment-root> <operator-home>
#   fm-omp-candidate-artifacts.sh launch-template
#   fm-omp-candidate-artifacts.sh validate-submission <text>
#   fm-omp-candidate-artifacts.sh extension <output> <busy-event> <state> <task-id> <generation> <turn-ended>
# `prepare` creates a new agent directory containing config.yml and a new,
# empty launch cwd. `manifest` emits the requested environment boundary and argv
# as JSON, including a clean environment whose configuration roots resolve under
# the isolated agent directory and flags that request disabled built-in tools and
# LSP. `verify-boundary` resolves that environment before launch and refuses any
# configuration source whose nearest existing ancestor escapes the containment
# root or aliases an operator-home compatibility source.
# `launch-template` emits the same boundary with spawn-time placeholders.
# `validate-submission` rejects text whose first non-whitespace character would
# enter OMP's slash-command or bang-command parser.
# `extension` writes the First Mate busy-state adapter to <output>. Persistent
# config and extension files are rendered beside their destinations and renamed
# atomically. No mode starts OMP, opens a session, or calls a provider.
set -eu

OMP_RETRY_JSON='{"modelFallback":false,"usageAwareFallback":false,"fallbackChains":{}}'
OMP_AST_EDIT_JSON='{"enabled":false}'

usage() {
  echo "usage: fm-omp-candidate-artifacts.sh prepare <agent-dir> <cwd> | manifest <agent-dir> <cwd> <binary> <model> <extension> | verify-boundary <manifest> <containment-root> <operator-home> | launch-template | validate-submission <text> | extension <output> <busy-event> <state> <task-id> <generation> <turn-ended>" >&2
  exit 2
}

atomic_publish() {
  local destination=$1 temporary=$2
  mv -f -- "$temporary" "$destination"
}

javascript_literal() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

render_config() {
  local destination=$1 temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXX") || exit 1
  if ! printf '%s\n' "{\"retry\":$OMP_RETRY_JSON,\"astEdit\":$OMP_AST_EDIT_JSON}" > "$temporary"; then
    rm -f -- "$temporary"
    exit 1
  fi
  atomic_publish "$destination" "$temporary"
}

prepare_isolated_settings() {
  local agent_dir=$1 cwd=$2
  if [ -e "$agent_dir" ] || [ -L "$agent_dir" ] || [ -e "$cwd" ] || [ -L "$cwd" ]; then
    echo "error: candidate OMP isolation directories already exist" >&2
    return 1
  fi
  mkdir -p \
    "$agent_dir/home/.claude" \
    "$agent_dir/home/.copilot" \
    "$agent_dir/home/.config/gh" \
    "$agent_dir/home/.config/chrome" \
    "$agent_dir/home/.aws" \
    "$agent_dir/home/.bun" \
    "$agent_dir/xdg/config" \
    "$agent_dir/xdg/data" \
    "$agent_dir/xdg/state" \
    "$agent_dir/xdg/cache" \
    "$agent_dir/tmp" \
    "$agent_dir/worktrees" \
    "$cwd" || return 1
  if ! render_config "$agent_dir/config.yml"; then
    rmdir "$cwd" "$agent_dir" 2>/dev/null || true
    return 1
  fi
}

render_manifest() {
  local agent_dir=$1 cwd=$2 binary=$3 model=$4 extension=$5
  OMP_AGENT_DIR=$agent_dir OMP_CWD=$cwd OMP_BINARY=$binary \
    OMP_MODEL=$model OMP_EXTENSION=$extension node <<'NODE'
const manifest = {
  unsetEnvironment: [
    "CLAUDECODE", "PI_CODING_AGENT", "PI_CONFIG_FILES", "OMP_PROFILE", "PI_PROFILE", "GROK_AGENT",
    "FM_PI_HARNESS", "CURSOR_AGENT", "CURSOR_INVOKED_AS", "TRACEPARENT",
  ],
  environment: {
    FM_OMP_HARNESS: "1",
    HOME: `${process.env.OMP_AGENT_DIR}/home`,
    PI_CODING_AGENT_DIR: process.env.OMP_AGENT_DIR,
    PI_CONFIG_DIR: ".omp",
    XDG_CONFIG_HOME: `${process.env.OMP_AGENT_DIR}/xdg/config`,
    XDG_DATA_HOME: `${process.env.OMP_AGENT_DIR}/xdg/data`,
    XDG_STATE_HOME: `${process.env.OMP_AGENT_DIR}/xdg/state`,
    XDG_CACHE_HOME: `${process.env.OMP_AGENT_DIR}/xdg/cache`,
    TMPDIR: `${process.env.OMP_AGENT_DIR}/tmp`,
    OMP_WORKTREE_DIR: `${process.env.OMP_AGENT_DIR}/worktrees`,
    CLAUDE_CONFIG_DIR: `${process.env.OMP_AGENT_DIR}/home/.claude`,
    COPILOT_HOME: `${process.env.OMP_AGENT_DIR}/home/.copilot`,
    GH_CONFIG_DIR: `${process.env.OMP_AGENT_DIR}/home/.config/gh`,
    AWS_CONFIG_FILE: `${process.env.OMP_AGENT_DIR}/home/.aws/config`,
    AWS_SHARED_CREDENTIALS_FILE: `${process.env.OMP_AGENT_DIR}/home/.aws/credentials`,
    CHROME_CONFIG_HOME: `${process.env.OMP_AGENT_DIR}/home/.config/chrome`,
    BUN_INSTALL: `${process.env.OMP_AGENT_DIR}/home/.bun`,
    GIT_CONFIG_GLOBAL: `${process.env.OMP_AGENT_DIR}/home/.gitconfig`,
    GIT_CONFIG_NOSYSTEM: "1",
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
    SHELL: "/bin/zsh",
    TERM: "xterm-256color",
  },
  argv: [
    process.env.OMP_BINARY,
    "--cwd", process.env.OMP_CWD,
    "--approval-mode", "yolo",
    "--no-title",
    "--no-extensions",
    "--no-skills",
    "--no-lsp",
    "--no-tools",
    "--model", process.env.OMP_MODEL,
    "-e", process.env.OMP_EXTENSION,
  ],
};
process.stdout.write(JSON.stringify(manifest));
NODE
}

verify_boundary() {
  local manifest=$1 containment_root=$2 operator_home=$3
  OMP_BOUNDARY_MANIFEST=$manifest OMP_CONTAINMENT_ROOT=$containment_root \
    OMP_OPERATOR_HOME=$operator_home node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const fail = (message) => {
  process.stderr.write(`error: OMP launch boundary refused: ${message}\n`);
  process.exit(1);
};
const nearestReal = (candidate) => {
  let cursor = path.resolve(candidate);
  const suffix = [];
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) fail(`cannot resolve a real ancestor for ${candidate}`);
    suffix.unshift(path.basename(cursor));
    cursor = parent;
  }
  return path.join(fs.realpathSync(cursor), ...suffix);
};
const inside = (root, candidate) => {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
};

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(process.env.OMP_BOUNDARY_MANIFEST, "utf8"));
} catch (error) {
  fail(`manifest is not readable JSON: ${error.message}`);
}
const root = fs.realpathSync(process.env.OMP_CONTAINMENT_ROOT);
const operatorHome = fs.realpathSync(process.env.OMP_OPERATOR_HOME);
const environment = manifest.environment || {};
const agent = nearestReal(environment.PI_CODING_AGENT_DIR || "");
const cwdIndex = Array.isArray(manifest.argv) ? manifest.argv.indexOf("--cwd") : -1;
const cwd = cwdIndex >= 0 ? nearestReal(manifest.argv[cwdIndex + 1] || "") : "";
if (!inside(root, agent)) fail("PI_CODING_AGENT_DIR escapes the containment root");
if (!cwd || !inside(root, cwd)) fail("--cwd escapes the containment root");

const expected = {
  HOME: path.join(agent, "home"),
  PI_CODING_AGENT_DIR: agent,
  PI_CONFIG_DIR: ".omp",
  XDG_CONFIG_HOME: path.join(agent, "xdg/config"),
  XDG_DATA_HOME: path.join(agent, "xdg/data"),
  XDG_STATE_HOME: path.join(agent, "xdg/state"),
  XDG_CACHE_HOME: path.join(agent, "xdg/cache"),
  TMPDIR: path.join(agent, "tmp"),
  OMP_WORKTREE_DIR: path.join(agent, "worktrees"),
  CLAUDE_CONFIG_DIR: path.join(agent, "home/.claude"),
  COPILOT_HOME: path.join(agent, "home/.copilot"),
  GH_CONFIG_DIR: path.join(agent, "home/.config/gh"),
  AWS_CONFIG_FILE: path.join(agent, "home/.aws/config"),
  AWS_SHARED_CREDENTIALS_FILE: path.join(agent, "home/.aws/credentials"),
  CHROME_CONFIG_HOME: path.join(agent, "home/.config/chrome"),
  BUN_INSTALL: path.join(agent, "home/.bun"),
  GIT_CONFIG_GLOBAL: path.join(agent, "home/.gitconfig"),
};
for (const [name, expectedValue] of Object.entries(expected)) {
  if (environment[name] === undefined) fail(`${name} is missing`);
  if (name === "PI_CONFIG_DIR") {
    if (environment[name] !== expectedValue) fail(`${name} is not the isolated relative root`);
    continue;
  }
  const actual = nearestReal(environment[name]);
  if (actual !== nearestReal(expectedValue)) fail(`${name} does not resolve to its isolated path`);
  if (!inside(root, actual)) fail(`${name} escapes the containment root`);
}
if (environment.GIT_CONFIG_NOSYSTEM !== "1") fail("GIT_CONFIG_NOSYSTEM is not enabled");

const home = nearestReal(environment.HOME);
const effectiveSources = [
  path.join(home, ".claude.json"),
  path.join(home, ".claude/mcp.json"),
  path.join(home, ".cursor/mcp.json"),
  path.join(home, ".gemini/settings.json"),
  path.join(home, ".codex/config.toml"),
  path.join(home, ".config/opencode/opencode.json"),
  path.join(home, ".codeium/windsurf/mcp_config.json"),
  path.join(home, ".vscode/mcp.json"),
  path.join(agent, "mcp.json"),
  path.join(cwd, ".mcp.json"),
  path.join(cwd, "mcp.json"),
  path.join(cwd, ".claude/.mcp.json"),
  path.join(cwd, ".claude/mcp.json"),
  path.join(cwd, ".cursor/mcp.json"),
  path.join(cwd, ".gemini/settings.json"),
  path.join(cwd, ".codex/config.toml"),
  path.join(cwd, ".opencode/opencode.json"),
  path.join(cwd, ".windsurf/mcp_config.json"),
  path.join(cwd, ".vscode/mcp.json"),
];
const operatorSources = new Set([
  path.join(operatorHome, ".claude.json"),
  path.join(operatorHome, ".claude/mcp.json"),
  path.join(operatorHome, ".cursor/mcp.json"),
  path.join(operatorHome, ".gemini/settings.json"),
  path.join(operatorHome, ".codex/config.toml"),
  path.join(operatorHome, ".config/opencode/opencode.json"),
  path.join(operatorHome, ".codeium/windsurf/mcp_config.json"),
  path.join(operatorHome, ".vscode/mcp.json"),
].map(nearestReal));
for (const source of effectiveSources.map(nearestReal)) {
  if (!inside(root, source)) fail(`effective compatibility source escapes containment: ${source}`);
  if (operatorSources.has(source)) fail(`effective compatibility source aliases operator configuration: ${source}`);
}
process.stdout.write(`boundary-ok roots=${Object.keys(expected).join(",")} sources=${effectiveSources.length}\n`);
NODE
}

render_launch_template() {
  render_manifest __OMPAGENTDIR__ __OMPCWD__ __OMPBIN__ __OMPMODEL__ __OMPEXT__ \
    | node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(0, "utf8"));
const words = ["env", "-i"];
for (const name of manifest.unsetEnvironment) words.push("-u", name);
for (const [name, value] of Object.entries(manifest.environment)) words.push(name + "=" + value);
words.push(...manifest.argv);
const dollar = String.fromCharCode(36);
process.stdout.write(words.join(" ") + " \"" + dollar + "(__OPINPUT__ encode launch-brief < __BRIEF__)\"");
'
}

validate_submission() {
  OMP_SUBMISSION=$1 node <<'NODE'
const input = process.env.OMP_SUBMISSION || "";
const command = input.trimStart();
if (command.startsWith("/") || command.startsWith("!")) {
  process.stderr.write("error: OMP candidate refuses slash and bang command input; use First Mate control for lifecycle actions\n");
  process.exit(1);
}
NODE
}

render_extension() {
  local destination=$1 busy_event=$2 state=$3 task_id=$4 generation=$5 turn_ended=$6
  local temporary busy_event_js state_js task_id_js generation_js turn_ended_js
  busy_event_js=$(javascript_literal "$busy_event") || exit 1
  state_js=$(javascript_literal "$state") || exit 1
  task_id_js=$(javascript_literal "$task_id") || exit 1
  generation_js=$(javascript_literal "$generation") || exit 1
  turn_ended_js=$(javascript_literal "$turn_ended") || exit 1
  temporary=$(mktemp "${destination}.tmp.XXXXXX") || exit 1
  if ! cat > "$temporary" <<EOF
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile($busy_event_js, [
      "apply", $state_js, $task_id_js, state,
      "--gen", $generation_js, "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (omp: any) {
  omp.on("agent_start", () => busyEvent("busy", "agent-start"));
  const settled = (event: any, ctx: any) => {
    if (event && event.willContinue === true) return;
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-end");
  };
  for (const name of ["agent_end", "agent_settled"]) {
    try {
      omp.on(name, settled);
    } catch (_err) {
    }
  }
  omp.on("turn_end", () => execFile("touch", [$turn_ended_js]));
}
EOF
  then
    rm -f -- "$temporary"
    exit 1
  fi
  atomic_publish "$destination" "$temporary"
}

case "${1:-}" in
  prepare)
    [ "$#" -eq 3 ] || usage
    prepare_isolated_settings "$2" "$3"
    ;;
  manifest)
    [ "$#" -eq 6 ] || usage
    render_manifest "$2" "$3" "$4" "$5" "$6"
    ;;
  verify-boundary)
    [ "$#" -eq 4 ] || usage
    verify_boundary "$2" "$3" "$4"
    ;;
  launch-template)
    [ "$#" -eq 1 ] || usage
    render_launch_template
    ;;
  validate-submission)
    [ "$#" -eq 2 ] || usage
    validate_submission "$2"
    ;;
  extension)
    [ "$#" -eq 7 ] || usage
    render_extension "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  *) usage ;;
esac
