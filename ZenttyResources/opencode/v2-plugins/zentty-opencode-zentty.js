// Zentty plugin for OpenCode v2 (`@opencode/cli`). v2 rejects the v1 named-export
// factory and its `event` hook: a plugin is a default `{ id, setup }` definition
// that reads the server event stream. Zentty launches v2 with `--standalone`, so
// this runs in the pane's private server child and `process.env` belongs to the
// pane. Node APIs only: v2 also ships a node build where `Bun` is undefined.
import { spawn, spawnSync } from "node:child_process"
import { accessSync, constants } from "node:fs"
import { delimiter, join } from "node:path"

const worklaneID = process.env.ZENTTY_WORKLANE_ID
const paneID = process.env.ZENTTY_PANE_ID
const socketPath = process.env.ZENTTY_INSTANCE_SOCKET
const paneToken = process.env.ZENTTY_PANE_TOKEN
const resolvedCliBin = process.env.ZENTTY_CLI_BIN || whichExecutable("zentty") || ""
const agentName = process.env.ZENTTY_AGENT_CANONICAL_NAME || "OpenCode"

const hasZenttyIntegration = Boolean(resolvedCliBin && socketPath && paneToken && worklaneID && paneID)

function whichExecutable(name) {
  for (const entry of (process.env.PATH || "").split(delimiter)) {
    if (!entry) continue
    const candidate = join(entry, name)
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {}
  }
  return undefined
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed) return trimmed
    }
  }
  return undefined
}

function canonicalBase(sessionID, cwd) {
  const base = { version: 1, agent: { name: agentName } }
  if (sessionID) base.session = { id: sessionID }
  if (cwd) base.context = { workingDirectory: cwd }
  return base
}

function describePermission(data) {
  const message = firstString(data.message)
  if (message) return message
  const action = firstString(data.action)
  const resources = Array.isArray(data.resources) ? data.resources.filter((r) => typeof r === "string") : []
  if (action && resources.length > 0) return `${action}: ${resources.join(", ")}`
  return action
}

function describeForm(form) {
  const lines = []
  const title = firstString(form?.title)
  if (title) lines.push(title)
  const fields = Array.isArray(form?.fields) ? form.fields : []
  const choice = fields.find((field) => Array.isArray(field?.options) && field.options.length > 0)
  const labels = choice ? choice.options.map((o) => firstString(o?.label, o?.value, o)).filter(Boolean) : []
  if (labels.length > 0) lines.push(labels.map((l) => `[${l}]`).join(" "))
  if (lines.length === 0) return undefined
  return { text: lines.join("\n"), kind: labels.length > 0 ? "decision" : "question" }
}

// Child sessions (subagents) report their own execution lifecycle; forwarding
// it would flip the pane to idle while the parent session is still running.
const childSessions = new Set()

export function toCanonicalEvent(event, cwd) {
  const type = firstString(event?.type)
  const data = event?.data ?? {}

  if (type === "session.created") {
    const sessionID = firstString(data.sessionID)
    if (sessionID && firstString(data.parentID)) childSessions.add(sessionID)
    return undefined
  }

  const sessionID = firstString(data.sessionID, data.form?.sessionID)
  if (sessionID && childSessions.has(sessionID)) return undefined
  const base = canonicalBase(sessionID, cwd)

  switch (type) {
    case "session.execution.started":
      return { ...base, event: "agent.running" }
    case "session.execution.succeeded":
    case "session.execution.failed":
    case "session.execution.interrupted":
      return { ...base, event: "agent.idle" }
    case "session.compaction.started":
      return { ...base, event: "agent.compacting", state: { text: "Compacting" } }
    case "session.compaction.ended":
    case "session.compaction.failed":
      return { ...base, event: "agent.compacted" }
    case "permission.asked":
      return {
        ...base,
        event: "agent.needs-input",
        state: {
          interaction: { kind: "approval", text: describePermission(data) || `${agentName} needs your approval` },
        },
      }
    case "permission.replied":
      return { ...base, event: "agent.input-resolved" }
    case "form.created": {
      const form = describeForm(data.form)
      return {
        ...base,
        event: "agent.needs-input",
        state: {
          interaction: { kind: form?.kind ?? "question", text: form?.text || `${agentName} is asking a question` },
        },
      }
    }
    case "form.replied":
    case "form.cancelled":
      return { ...base, event: "agent.input-resolved" }
    default:
      return undefined
  }
}

// The standalone server exits with its client (`opencode run` finishing, the
// TUI quitting), which can cut an async pipe write short. Idle is the event
// most likely to race shutdown, so it is delivered synchronously.
const synchronousEvents = new Set(["agent.idle"])

function forwardCanonical(canonical) {
  if (!hasZenttyIntegration || !canonical) return Promise.resolve()

  if (synchronousEvents.has(canonical.event)) {
    try {
      spawnSync(resolvedCliBin, ["ipc", "agent-event"], {
        input: `${JSON.stringify(canonical)}\n`,
        stdio: ["pipe", "ignore", "ignore"],
        env: process.env,
        timeout: 5000,
      })
    } catch {}
    return Promise.resolve()
  }

  return new Promise((resolve) => {
    let child
    try {
      child = spawn(resolvedCliBin, ["ipc", "agent-event"], {
        stdio: ["pipe", "ignore", "ignore"],
        env: process.env,
      })
    } catch {
      resolve()
      return
    }
    child.on("error", () => resolve())
    child.on("close", () => resolve())
    child.stdin.on("error", () => {})
    child.stdin.end(`${JSON.stringify(canonical)}\n`)
  })
}

export default {
  id: "zentty",
  setup: (ctx) => {
    if (!hasZenttyIntegration) return

    const cwd = firstString(ctx?.location?.directory)
    const controller = new AbortController()
    // Setup must return promptly; the subscription lives until cleanup aborts it.
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          await forwardCanonical(toCanonicalEvent(event, cwd))
        }
      } catch {}
    })()

    return () => controller.abort()
  },
}
