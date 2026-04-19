const { spawn } = require("node:child_process")

const worklaneID = process.env.ZENTTY_WORKLANE_ID
const paneID = process.env.ZENTTY_PANE_ID
const socketPath = process.env.ZENTTY_INSTANCE_SOCKET
const paneToken = process.env.ZENTTY_PANE_TOKEN
const resolvedCliBin = process.env.ZENTTY_CLI_BIN || ""

const hasZenttyIntegration = Boolean(resolvedCliBin && socketPath && paneToken && worklaneID && paneID)

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed) return trimmed
    }
  }
  return undefined
}

function describeSession(event) {
  if (!event || typeof event !== "object") return { sessionID: undefined, cwd: undefined }
  return {
    sessionID: firstString(event.sessionId, event.sessionID, event.session?.id, event.id),
    cwd: firstString(event.cwd, event.workingDirectory, event.session?.cwd, event.session?.workingDirectory),
  }
}

// Each forward() spawns an independent `zentty ipc agent-event` child.
// On pi's /reload, session_shutdown + session_start fire back-to-back, so
// without ordering we can't guarantee session.end arrives before the
// following session.start — Zentty would clear state AFTER the restart.
// Chain spawns on a single promise tail so each child's exit is awaited
// before the next one starts. Handlers are still fire-and-forget from
// pi's perspective; we never block pi's event loop on Zentty I/O.
let pendingTail = Promise.resolve()

function forward(canonical) {
  if (!hasZenttyIntegration || !canonical) return
  const payload = `${JSON.stringify(canonical)}\n`
  pendingTail = pendingTail
    .then(() => new Promise((resolve) => {
      try {
        const child = spawn(resolvedCliBin, ["ipc", "agent-event"], {
          stdio: ["pipe", "ignore", "ignore"],
          env: process.env,
        })
        let done = false
        const finish = () => {
          if (done) return
          done = true
          resolve()
        }
        child.on("error", finish)
        child.on("exit", finish)
        // Swallow EPIPE etc. if the CLI exits before we finish writing —
        // pi must keep running even when the Zentty IPC path is broken.
        child.stdin.on("error", () => {})
        child.stdin.end(payload)
      } catch {
        // Never crash pi because of Zentty integration.
        resolve()
      }
    }))
    .catch(() => {}) // Never let the chain reject and leak.
}

function baseEnvelope(event) {
  const { sessionID, cwd } = describeSession(event)
  const envelope = { version: 1, agent: { name: "Pi" } }
  if (sessionID) envelope.session = { id: sessionID }
  if (cwd) envelope.context = { workingDirectory: cwd }
  return envelope
}

module.exports = function (pi) {
  if (!hasZenttyIntegration) return

  // Pi fires session_start for startup, reload, resume, new, and fork —
  // piPlan's pre-launch action only covers the first case, so we re-emit
  // session.start here to reset Zentty state on every session boundary.
  pi.on("session_start", async (event) => {
    forward({ ...baseEnvelope(event), event: "session.start" })
  })
  // Pi fires both agent_start/end and turn_start/end around every turn —
  // hook only agent_* to avoid duplicate events (matches notify.ts and
  // titlebar-spinner.ts in pi-mono's own examples/).
  pi.on("agent_start", async (event) => {
    forward({ ...baseEnvelope(event), event: "agent.running" })
  })
  pi.on("agent_end", async (event) => {
    forward({ ...baseEnvelope(event), event: "agent.idle" })
  })
  // session_shutdown fires on graceful exit (double Ctrl+C / Ctrl+D via
  // dispose() → process.exit(0)) and also on reload/resume/fork. Emit
  // session.end — a lifecycle payload with state=nil that clears Zentty's
  // agent status (including the "Agent ready" ready-label). On reload etc.
  // the subsequent session_start restores it.
  pi.on("session_shutdown", async (event) => {
    forward({ ...baseEnvelope(event), event: "session.end" })
  })
}

module.exports.default = module.exports
