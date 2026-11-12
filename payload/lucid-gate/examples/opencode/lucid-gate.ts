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
// Set LUCID_GATE_DISABLE=1 to get out of the way for a session.

import { Plugin } from "@opencode/plugin"
import { readFileSync } from "node:fs"

const HOME = process.env.HOME ?? ""
const BIN = process.env.LUCID_GATE_BIN ?? `${HOME}/.local/bin/gate`
const STATE = `${HOME}/.local/state/lucid-gate/state.json`
const PLACE = "opencode"
const WAIT_MS = 30 * 60 * 1000

type Pending = { gate: string; sessionID: string; text: string }

function hash(text: string): string {
  let value = 0
  for (let i = 0; i < text.length; i++) value = (value * 31 + text.charCodeAt(i)) | 0
  return (value >>> 0).toString(36)
}

function requestGate(sessionID: string, text: string): string | null {
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

function gateState(gateID: string): string | null {
  try {
    const state = JSON.parse(readFileSync(STATE, "utf8"))
    return state?.gates?.[gateID]?.state ?? null
  } catch {
    return null
  }
}

async function waitForGate(gateID: string): Promise<"granted" | "cancelled" | "timeout"> {
  const deadline = Date.now() + WAIT_MS
  while (Date.now() < deadline) {
    const state = gateState(gateID)
    if (state === "granted") return "granted"
    if (state === "cancelled") return "cancelled"
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
    await ctx.session.hook("prompt", (event) => {
      const text = event.prompt.text ?? ""
      if (!text.trim()) return

      const gate = requestGate(event.sessionID, text)
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
