// src/infrastructure/config.ts
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
var parseYaml = (text) => {
  const hooks = [];
  let current = null;
  const lines = text.split(`
`);
  for (const raw of lines) {
    const line = raw.trimEnd();
    if (line.trim() === "" || line.trimStart().startsWith("#"))
      continue;
    const listStart = line.match(/^  - (\w+):\s*(.*)/);
    if (listStart) {
      if (current)
        hooks.push(current);
      current = { [listStart[1]]: listStart[2].trim() };
      continue;
    }
    if (!current)
      continue;
    const propMatch = line.match(/^\s+(\w+):\s*(.*)/);
    const bashMatch = line.match(/^\s+- bash:\s*(.*)/);
    if (!propMatch && !bashMatch)
      continue;
    if (bashMatch) {
      if (!current.actions || !Array.isArray(current.actions))
        current.actions = [];
      current.actions.push({ bash: bashMatch[1].trim().replace(/^["']|["']$/g, "") });
      continue;
    }
    const key = propMatch[1];
    const val = propMatch[2].trim();
    if (key === "tools" && val.startsWith("[")) {
      current.tools = val.slice(1, -1).split(",").map((s) => s.trim().replace(/['"]/g, ""));
    } else if (key === "actions") {
      if (!current.actions)
        current.actions = [];
    } else {
      current[key] = val;
    }
  }
  if (current)
    hooks.push(current);
  return { hooks };
};
var GLOBAL_PATH = join(homedir(), ".config", "opencode", "hooks.yaml");
var PROJECT_PATH = ".opencode/hooks.yaml";
var loadConfig = (worktree) => {
  const allHooks = [];
  if (existsSync(GLOBAL_PATH)) {
    const global = parseYaml(readFileSync(GLOBAL_PATH, "utf-8"));
    allHooks.push(...global.hooks);
  }
  const projectPath = join(worktree, PROJECT_PATH);
  if (existsSync(projectPath)) {
    const project = parseYaml(readFileSync(projectPath, "utf-8"));
    const ids = new Set(project.hooks.map((h) => h.id).filter(Boolean));
    const filtered = allHooks.filter((h) => !ids.has(h.id));
    allHooks.length = 0;
    allHooks.push(...filtered, ...project.hooks);
  }
  return { hooks: allHooks };
};

// src/infrastructure/executor.ts
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
var exec = (command, timeoutMs = 120000) => {
  let result;
  try {
    result = spawnSync(command, {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf-8",
      shell: true,
      timeout: timeoutMs
    });
  } catch (err) {
    return {
      exitCode: err?.exitCode ?? 1,
      stdout: (typeof err?.stdout?.toString === "function" ? err.stdout.toString() : err?.stdout || "").trim(),
      stderr: (typeof err?.stderr?.toString === "function" ? err.stderr.toString() : err?.stderr || err?.message || "").trim(),
    };
  }
  return {
    exitCode: result.status ?? 1,
    stdout: (result.stdout || "").trim(),
    stderr: (result.stderr || "").trim()
  };
};

// src/application/hooks.ts
var runActions = (actions, label) => {
  let lastOutput = "";
  for (const action of actions) {
    const result = exec(action.bash);
    appendFileSync("/tmp/oh.log", `code=${result.exitCode} out=${result.stdout.length} err=${result.stderr.length}\n`);
    lastOutput = (result.stdout + "\n" + result.stderr).trim();
  }
  return lastOutput;
};
var registerHooks = (config) => {
  const toolHooks = {};
  const sessionHooks = [];
  for (const entry of config.hooks) {
    if ("tools" in entry) {
      if (!toolHooks[entry.event])
        toolHooks[entry.event] = [];
      toolHooks[entry.event].push(entry);
    } else if (entry.event.startsWith("session.")) {
      sessionHooks.push(entry);
    }
  }
  const hooks = {};
  for (const [event, entries] of Object.entries(toolHooks)) {
    if (event === "tool.execute.before" || event === "tool.execute.after") {
      hooks[event] = async (input, output) => {
        const toolInput = input;
        for (const entry of entries) {
          if (entry.tools && !entry.tools.includes(toolInput.tool))
            continue;
      if (output) {
        output.title = entry.id || event;
        output.output = runActions(entry.actions, entry.id || event);
      } else {
        runActions(entry.actions, entry.id || event);
      }
        }
      };
    }
  }
  if (sessionHooks.length > 0) {
    hooks.event = async (input) => {
      const type = input.event.type;
      for (const entry of sessionHooks) {
        const sessionEvent = entry.event.replace("session.", "");
        if (type !== sessionEvent && type !== entry.event)
          continue;
        try {
          runActions(entry.actions, entry.id || entry.event);
        } catch (e) {
          console.error(`openhooks: session hook failed: ${e}`);
        }
      }
    };
  }
  return hooks;
};

// index.ts
var OpenhooksPlugin = async (ctx) => {
  const root = ctx.worktree || ctx.directory || ctx.project?.root || process.cwd();
  const config = loadConfig(root);
  return registerHooks(config);
};
var openhooks_default = OpenhooksPlugin;
export {
  openhooks_default as default,
  OpenhooksPlugin
};
