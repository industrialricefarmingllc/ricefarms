/**
 * Publishes the sessions open in this TUI window for the Lucid desktop widget.
 *
 * Each OpenCode TUI process owns one snapshot file under
 * `$XDG_RUNTIME_DIR/opencode-lucid-sessions/`. The widget's helper merges them,
 * so several terminal windows can be open at once.
 *
 * This plugin is deliberately dependency-free beyond `@opencode/plugin/tui`.
 * It never talks to the OpenCode server directly: the parts of the TUI context
 * it needs are passed in as a small structural interface, which also makes the
 * collector testable without a running TUI.
 */
import { Plugin } from "@opencode/plugin/tui"
import { execFile } from "node:child_process"
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

export type SessionStatus = "busy" | "attention" | "idle"

export interface SessionSnapshot {
  id: string
  title: string
  status: SessionStatus
  active: boolean
  attention: boolean
  unread: "activity" | "error" | null
  directory: string | null
  updatedAt: number
  doneAt: number | null
}

export interface WindowSnapshot {
  version: 1
  pid: number
  startTicks: string
  tabs: boolean
  active: string | null
  windowPid: number | null
  windowAddress: string | null
  updatedAt: number
  sessions: SessionSnapshot[]
}

/** The pieces of the TUI context the collector reads. */
export interface OpenSessionSource {
  tabs: {
    enabled(): boolean
    list(): readonly {
      readonly sessionID: string
      readonly title?: string
      readonly active: boolean
      readonly busy: boolean
      readonly attention: boolean
      readonly unread?: "activity" | "error"
    }[]
  }
  router: {
    current(): { readonly type: string; readonly sessionID?: string }
  }
  session: {
    get(sessionID: string):
      | { readonly title?: string; readonly location?: { readonly directory?: string }; readonly time?: { readonly idle?: number } }
      | undefined
    status(sessionID: string): "idle" | "running"
  }
}

export interface HyprlandWindow {
  pid: number
  address: string
}

const SNAPSHOT_PREFIX = "window-"

export function stateDirectory(env: Record<string, string | undefined> = process.env): string {
  const base = env.XDG_RUNTIME_DIR || join(homedir(), ".cache")
  return join(base, "opencode-lucid-sessions")
}

function snapshotPath(snapshot: Pick<WindowSnapshot, "pid" | "startTicks">, env?: Record<string, string | undefined>): string {
  return join(stateDirectory(env), `${SNAPSHOT_PREFIX}${snapshot.pid}-${snapshot.startTicks}.json`)
}

function safe<T>(read: () => T, fallback: T): T {
  try {
    return read()
  } catch {
    return fallback
  }
}

/**
 * Field 22 of /proc/<pid>/stat. PID plus start time identifies a process
 * without the PID-reuse race a bare PID has.
 */
export async function processStartTicks(pid: number): Promise<string> {
  try {
    const stat = await readFile(`/proc/${pid}/stat`, "utf8")
    const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/)
    return fields[19] ?? "0"
  } catch {
    return "0"
  }
}

function titleOf(value: string | undefined): string {
  const title = (value ?? "").trim()
  return title === "" ? "Untitled session" : title
}

/**
 * Snapshot of the root sessions open in one TUI window.
 *
 * With tabs enabled, every open session tab counts, including background ones.
 * With tabs disabled, the window has one session on screen, so the current
 * route is the only open session.
 */
export function collectWindow(
  source: OpenSessionSource,
  pid: number,
  startTicks: string,
  now = Date.now(),
  previous?: Map<string, SessionSnapshot>,
): WindowSnapshot {
  const tabsEnabled = safe(() => source.tabs.enabled(), false)
  const tabList = tabsEnabled ? safe(() => source.tabs.list(), []) : []
  const sessions: SessionSnapshot[] = []
  let active: string | null = null

  // Stamps only move when the session itself changes. doneAt records the
  // transition into idle so the widget can sort finished sessions by age.
  const snapshotOf = (
    id: string,
    title: string,
    status: SessionStatus,
    isActive: boolean,
    attention: boolean,
    unread: "activity" | "error" | null,
    directory: string | null,
    doneHint?: number,
  ): SessionSnapshot => {
    const before = previous?.get(id)
    const unchanged =
      before !== undefined &&
      before.title === title &&
      before.status === status &&
      before.active === isActive &&
      before.attention === attention &&
      before.unread === unread &&
      before.directory === directory
    const observed = before?.status === "idle" ? (before.doneAt ?? now) : now
    const doneAt =
      status === "idle" ? (typeof doneHint === "number" ? doneHint : observed) : null
    return {
      id,
      title,
      status,
      active: isActive,
      attention,
      unread,
      directory,
      updatedAt: unchanged ? before.updatedAt : now,
      doneAt,
    }
  }

  if (tabList.length > 0) {
    for (const tab of tabList) {
      const info = safe(() => source.session.get(tab.sessionID), undefined)
      const attention = tab.attention === true || tab.unread === "error"
      sessions.push(
        snapshotOf(
          tab.sessionID,
          titleOf((tab.title ?? "").trim() || info?.title),
          tab.busy ? "busy" : attention ? "attention" : "idle",
          tab.active === true,
          attention,
          tab.unread ?? null,
          info?.location?.directory ?? null,
          info?.time?.idle,
        ),
      )
      if (tab.active) active = tab.sessionID
    }
  } else {
    const route = safe(() => source.router.current(), { type: "home" })
    if (route.type === "session" && typeof route.sessionID === "string") {
      const id = route.sessionID
      const info = safe(() => source.session.get(id), undefined)
      const running = safe(() => source.session.status(id) === "running", false)
      sessions.push(
        snapshotOf(id, titleOf(info?.title), running ? "busy" : "idle", true, false, null, info?.location?.directory ?? null, info?.time?.idle),
      )
      active = id
    }
  }

  return {
    version: 1,
    pid,
    startTicks,
    tabs: tabsEnabled,
    active,
    windowPid: null,
    windowAddress: null,
    updatedAt: now,
    sessions,
  }
}

/** Atomically replace this window's snapshot. Readers never see half a file. */
export async function publishWindow(snapshot: WindowSnapshot, env?: Record<string, string | undefined>): Promise<string> {
  const file = snapshotPath(snapshot, env)
  await mkdir(stateDirectory(env), { recursive: true, mode: 0o700 })
  const temporary = `${file}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(snapshot)}\n`, { mode: 0o600 })
  await rename(temporary, file)
  return file
}

export async function removeWindow(
  snapshot: Pick<WindowSnapshot, "pid" | "startTicks">,
  env?: Record<string, string | undefined>,
): Promise<void> {
  try {
    await unlink(snapshotPath(snapshot, env))
  } catch {
    // already gone, or never written
  }
}

function readParentPid(pid: number): Promise<number | null> {
  return readFile(`/proc/${pid}/status`, "utf8")
    .then((status) => {
      const match = status.match(/^PPid:\s*(\d+)/m)
      return match ? Number(match[1]) : null
    })
    .catch(() => null)
}

function hyprlandClients(): Promise<Array<{ pid: number; address: string }>> {
  return new Promise((resolve) => {
    execFile("hyprctl", ["clients", "-j"], { timeout: 1500 }, (error, stdout) => {
      if (error) return resolve([])
      try {
        const clients = JSON.parse(stdout) as Array<{ pid?: number; address?: string }>
        resolve(
          clients.flatMap((client) =>
            typeof client.pid === "number" && typeof client.address === "string"
              ? [{ pid: client.pid, address: client.address }]
              : [],
          ),
        )
      } catch {
        resolve([])
      }
    })
  })
}

/**
 * The Hyprland client that owns this process. OpenCode runs inside a terminal
 * emulator (or tmux), so walk the parent chain and match the compositor's
 * client PIDs. Returns null outside Hyprland, which only loses click-to-focus.
 */
export async function findHyprlandWindow(pid: number): Promise<HyprlandWindow | null> {
  const clients = await hyprlandClients()
  if (clients.length === 0) return null
  const byPid = new Map(clients.map((client) => [client.pid, client]))
  let current: number | null = pid
  for (let depth = 0; depth < 16 && current !== null && current > 1; depth++) {
    const client = byPid.get(current)
    if (client) return client
    current = await readParentPid(current)
  }
  return null
}

export default Plugin.define({
  id: "lucid-sessions",
  async setup(ctx) {
    const pid = process.pid
    const startTicks = await processStartTicks(pid)
    const identity = { pid, startTicks }
    const source: OpenSessionSource = {
      tabs: ctx.ui.tabs,
      router: ctx.ui.router,
      session: ctx.data.session,
    }

    let windowInfo: HyprlandWindow | null = null
    let disposed = false
    let lastBody = ""
    let previous: Map<string, SessionSnapshot> | undefined
    let chain: Promise<void> = Promise.resolve()

    const flush = async () => {
      if (disposed) return
      const snapshot = collectWindow(source, pid, startTicks, Date.now(), previous)
      snapshot.windowPid = windowInfo?.pid ?? null
      snapshot.windowAddress = windowInfo?.address ?? null
      // updatedAt is when this state last changed, so it must not take part in
      // the comparison or every poll would look like a change.
      const body = JSON.stringify({
        ...snapshot,
        updatedAt: 0,
        sessions: snapshot.sessions.map((session) => ({ ...session, updatedAt: 0 })),
      })
      if (body === lastBody) return
      lastBody = body
      try {
        await publishWindow(snapshot)
        previous = new Map(snapshot.sessions.map((session) => [session.id, session]))
      } catch {
        // A missing runtime directory or a full disk must not break the TUI.
      }
    }

    const schedule = () => {
      chain = chain.then(flush).catch(() => {})
    }

    // The first write does not wait for Hyprland; the window lookup below
    // enriches the snapshot as soon as it answers.
    await flush()
    schedule()

    void findHyprlandWindow(pid).then((found) => {
      if (disposed || !found) return
      windowInfo = found
      schedule()
    })

    const timer = setInterval(schedule, 500)
    const offs: Array<() => void> = []
    const eventTypes = [
      "session.created",
      "session.renamed",
      "session.deleted",
      "session.status",
      "session.idle",
      "session.execution.started",
      "session.execution.succeeded",
      "session.execution.failed",
      "session.execution.interrupted",
    ] as const
    for (const type of eventTypes) {
      try {
        offs.push(ctx.data.on(type, schedule))
      } catch {
        // An older host without this event name; polling still covers it.
      }
    }

    return async () => {
      disposed = true
      clearInterval(timer)
      for (const off of offs) {
        try {
          off()
        } catch {}
      }
      await chain.catch(() => {})
      await removeWindow(identity)
    }
  },
})
