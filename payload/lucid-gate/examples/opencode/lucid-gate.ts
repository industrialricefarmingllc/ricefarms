// lucid-gate for OpenCode.
//
// Install as ~/.config/opencode/plugins/lucid-gate.ts.
//
// The prompt is admitted normally, so the composer clears like any other
// message. The gate is created in the prompt hook and the first model request
// of that turn is held in the context hook until the gate is granted. The
// overlay locks the terminal in the meantime; the prompt then goes through on
// its own, exactly once.
//
// This is deliberately not a throw-and-replay: refusing admission leaves the
// draft in the composer and duplicates the message when it is sent again.
//
// Subagent sessions (a child session with a parentID) are never gated: their
// prompt is part of a turn that was already admitted, so charging again would
// be double billing and would stall the parent waiting on them.
//
// A prompt that arrives while its session is already working (busy) is a
// follow-up to the turn that was just paid for, so it is admitted without
// another gate. Sessions listed in ~/.config/lucid-gate/exempt-sessions are
// never gated either. With the shell down there is no lock screen to show, so
// prompts auto-pass (and a gate already waiting is cancelled).
//
// Set LUCID_GATE_DISABLE=1 to get out of the way for a session.

import { Plugin } from "@opencode/plugin"
import { readFileSync, statSync } from "node:fs"

const HOME = process.env.HOME ?? ""
const BIN = process.env.LUCID_GATE_BIN ?? `${HOME}/.local/bin/gate`
const STATE = `${HOME}/.local/state/lucid-gate/state.json`
const EXEMPT = `${HOME}/.config/lucid-gate/exempt-sessions`
const ALIVE = `${HOME}/.local/state/lucid-gate/shell-alive`
const SHELL_STALE_MS = 6000
const RUNTIME = process.env.XDG_RUNTIME_DIR ?? `/run/user/${typeof process.getuid === "function" ? process.getuid() : 1000}`
const SOCKET = `${RUNTIME}/lucid-gate.sock`
const PLACE = "opencode"
const WAIT_MS = 30 * 60 * 1000

type Pending = { gate: string; sessionID: string; text: string }

// One session id per line; blank lines and # comments are ignored. Read on
// every prompt so a newly exempted session does not need a plugin reload.
function isExempt(sessionID: string): boolean {
  try {
    for (const line of readFileSync(EXEMPT, "utf8").split("\n")) {
      const id = line.trim()
      if (!id || id.startsWith("#")) continue
      if (id === sessionID) return true
    }
  } catch {
    return false
  }
  return false
}

// Subagents, exempt sessions, and prompts sent while the session is already
// working are all part of a turn that was already paid for: no gate, no wait.
async function shouldSkip(ctx: any, sessionID: string | undefined): Promise<boolean> {
  if (!sessionID) return false
  if (isExempt(sessionID)) return true
  try {
    const session = await ctx.session.get({ sessionID })
    if (session?.parentID) return true
    const time = session?.time || {}
    if (time.busy && (!time.idle || time.busy > time.idle)) return true
  } catch {
    return false
  }
  return false
}

// the shell touches this file every 2 s; a stale heartbeat means there is no
// lock screen to draw, so gating would only block the prompt
function shellRunning(): boolean {
  try {
    return Date.now() - statSync(ALIVE).mtimeMs < SHELL_STALE_MS
  } catch {
    return false
  }
}

function hash(text: string): string {
  let value = 0
  for (let i = 0; i < text.length; i++) value = (value * 31 + text.charCodeAt(i)) | 0
  return (value >>> 0).toString(36)
}

// The daemon is a local Unix socket; going straight to it skips a Python
// process start (~40-60 ms) on the critical path between Enter and the gate.
function requestGateSocket(sessionID: string, text: string): Promise<string | null> {
  return new Promise((resolve) => {
    let settled = false
    let buffer = ""
    let timer: ReturnType<typeof setTimeout>
    const finish = (value: string | null) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    timer = setTimeout(() => finish(null), 800)
    Bun.connect({
      unix: SOCKET,
      socket: {
        open(socket) {
          socket.write(JSON.stringify({
            cmd: "request",
            place: PLACE,
            label: "Send a message",
            ref: `opencode:${sessionID}:${hash(text)}`,
          }) + "\n")
        },
        data(socket, chunk) {
          buffer += chunk.toString()
          const newline = buffer.indexOf("\n")
          if (newline < 0) return
          try {
            const parsed = JSON.parse(buffer.slice(0, newline))
            finish(parsed.gate?.id ?? null)
          } catch {
            finish(null)
          }
          socket.end()
        },
        error() {
          finish(null)
        },
        close() {
          finish(null)
        },
      },
    }).catch(() => finish(null))
  })
}

function requestGateCli(sessionID: string, text: string): string | null {
  try {
    const proc = Bun.spawnSync({
      cmd: [
        BIN,
        "request",
        "--place", PLACE,
        "--label", "Send a message",
        "--ref", `opencode:${sessionID}:${hash(text)}`,
        "--json",
      ],
      stdout: "pipe",
      stderr: "pipe",
    })
    if (proc.exitCode !== 0) return null
    const parsed = JSON.parse(proc.stdout.toString() || "{}")
    return parsed.gate?.id ?? null
  } catch {
    return null
  }
}

// The daemon exits when idle; the CLI starts it again. Only the first prompt
// after an idle period pays for that.
async function requestGate(sessionID: string, text: string): Promise<string | null> {
  const fast = await requestGateSocket(sessionID, text)
  if (fast !== null) return fast
  return requestGateCli(sessionID, text)
}

function gateState(gateID: string): string | null {
  try {
    const state = JSON.parse(readFileSync(STATE, "utf8"))
    return state?.gates?.[gateID]?.state ?? null
  } catch {
    return null
  }
}

function cancelGate(gateID: string): void {
  try {
    Bun.spawnSync({ cmd: [BIN, "cancel", gateID], stdout: "pipe", stderr: "pipe" })
  } catch {}
}

async function waitForGate(gateID: string): Promise<"granted" | "cancelled" | "timeout"> {
  const deadline = Date.now() + WAIT_MS
  while (Date.now() < deadline) {
    const state = gateState(gateID)
    if (state === "granted") return "granted"
    if (state === "cancelled") return "cancelled"
    if (!shellRunning()) {
      // the lock screen went away mid-wait: do not leave the prompt hanging
      cancelGate(gateID)
      return "granted"
    }
    await new Promise((resolve) => setTimeout(resolve, 400))
  }
  return "timeout"
}

export default Plugin.define({
  id: "lucid-gate",

  async setup(ctx) {
    if (process.env.LUCID_GATE_DISABLE === "1") return

    const pending: Pending[] = []

    // Admission: open the gate now. No throw, so the TUI clears the composer.
    await ctx.session.hook("prompt", async (event) => {
      const text = event.prompt.text ?? ""
      if (!text.trim()) return
      if (!shellRunning()) return
      if (await shouldSkip(ctx, event.sessionID)) return

      const gate = await requestGate(event.sessionID, text)
      if (gate === null) return // no daemon: never block work
      pending.push({ gate, sessionID: event.sessionID, text })
    })

    // The first model request of the turn waits here. The session is already
    // committed; when the gate opens, generation simply continues.
    await ctx.session.hook("context", async (event) => {
      const index = pending.findIndex((item) => !event.sessionID || item.sessionID === event.sessionID)
      if (index < 0) return

      const item = pending.splice(index, 1)[0]
      const result = await waitForGate(item.gate)
      if (result !== "granted") {
        throw new Error(
          result === "cancelled"
            ? "Lucid Gate: the place stayed locked, so this turn was stopped."
            : "Lucid Gate: no task was finished, so this turn was stopped.",
        )
      }
    })
  },
})
