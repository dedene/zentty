const worklaneID = process.env.ZENTTY_WORKLANE_ID
const paneID = process.env.ZENTTY_PANE_ID
const socketPath = process.env.ZENTTY_INSTANCE_SOCKET
const paneToken = process.env.ZENTTY_PANE_TOKEN
const resolvedCliBin = process.env.ZENTTY_CLI_BIN || Bun.which("zentty") || ""

const hasZenttyIntegration = Boolean(resolvedCliBin && socketPath && paneToken && worklaneID && paneID)
const sessionWorkingDirectories = new Map()
const sessionTaskProgress = new Map()

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed) return trimmed
    }
  }
  return undefined
}

function firstNumber(...values) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) {
      return value
    }
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (!trimmed) continue
      const parsed = Number(trimmed)
      if (Number.isFinite(parsed)) return parsed
    }
  }
  return undefined
}

function normalizeTaskProgress(doneCount, totalCount) {
  if (!Number.isFinite(totalCount) || totalCount <= 0) return undefined
  const clampedDone = Math.max(0, Math.min(Math.trunc(doneCount ?? 0), Math.trunc(totalCount)))
  return {
    taskProgressDoneCount: clampedDone,
    taskProgressTotalCount: Math.trunc(totalCount),
  }
}

function isCompletedTodo(todo) {
  if (!todo || typeof todo !== "object") return false
  if (todo.completed === true || todo.done === true) return true
  const status = firstString(todo.status, todo.state?.status, todo.state)
  return ["completed", "complete", "done", "finished"].includes((status ?? "").toLowerCase())
}

function extractTodoArray(properties) {
  const candidates = [
    properties.todos,
    properties.items,
    properties.todo?.items,
    properties.todo?.todos,
    properties.state?.todos,
    properties.state?.items,
    properties.snapshot?.todos,
    properties.snapshot?.items,
  ]

  return candidates.find(Array.isArray)
}

function resolveTaskProgress(properties) {
  const direct = normalizeTaskProgress(
    firstNumber(
      properties.doneCount,
      properties.done,
      properties.completedCount,
      properties.completed,
      properties.progress?.doneCount,
      properties.progress?.done,
      properties.progress?.completedCount,
      properties.progress?.completed,
    ),
    firstNumber(
      properties.totalCount,
      properties.total,
      properties.count,
      properties.progress?.totalCount,
      properties.progress?.total,
      properties.progress?.count,
    ),
  )
  if (direct) return direct

  const todos = extractTodoArray(properties)
  if (!Array.isArray(todos) || todos.length === 0) return undefined

  const doneCount = todos.filter(isCompletedTodo).length
  return normalizeTaskProgress(doneCount, todos.length)
}

function rememberTaskProgress(sessionID, progress) {
  if (!sessionID) return
  if (progress) {
    sessionTaskProgress.set(sessionID, progress)
  } else {
    sessionTaskProgress.delete(sessionID)
  }
}

function enrichWithTaskProgress(sessionID, envelope) {
  if (!sessionID) return envelope
  const progress = sessionTaskProgress.get(sessionID)
  if (!progress) return envelope
  return {
    ...envelope,
    ...progress,
  }
}

function rememberWorkingDirectory(sessionID, cwd) {
  if (sessionID && cwd) {
    sessionWorkingDirectories.set(sessionID, cwd)
  }
}

function resolveWorkingDirectory(sessionID, cwd, fallbackDirectory) {
  const resolved = firstString(cwd, sessionID ? sessionWorkingDirectories.get(sessionID) : undefined, fallbackDirectory)
  rememberWorkingDirectory(sessionID, resolved)
  return resolved
}

function normalizeEnvelope(event, fallbackDirectory) {
  const properties = event?.properties ?? {}
  const eventType = firstString(event?.type)
  const sessionID = firstString(
    properties.sessionID,
    properties.id,
    properties.info?.id,
    properties.permission?.sessionID,
    properties.tool?.sessionID,
    properties.todo?.sessionID,
  )

  if (eventType === "session.created" || eventType === "session.updated") {
    const cwd = firstString(properties.info?.directory)
    rememberWorkingDirectory(sessionID, cwd)
    return null
  }

  if (eventType === "session.status") {
    const cwd = resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory)
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd,
      status: firstString(properties.status?.type, properties.status),
    })
  }

  if (eventType === "session.idle") {
    const cwd = resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory)
    sessionWorkingDirectories.delete(sessionID)
    const envelope = enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd,
    })
    sessionTaskProgress.delete(sessionID)
    return envelope
  }

  if (eventType === "permission.asked" || eventType === "permission.updated") {
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
      title: firstString(properties.title, properties.permission?.title, properties.metadata?.title),
    })
  }

  if (eventType === "permission.replied") {
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
    })
  }

  if (eventType === "question.asked") {
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
      questions: Array.isArray(properties.questions) ? properties.questions : [],
    })
  }

  if (eventType === "question.replied") {
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
    })
  }

  if (eventType === "todo.updated") {
    const progress = resolveTaskProgress(properties)
    rememberTaskProgress(sessionID, progress)
    return enrichWithTaskProgress(sessionID, {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
    })
  }

  if (eventType === "message.part.updated") {
    const part = properties.part ?? {}
    const partSessionID = firstString(part.sessionID, sessionID)
    const toolName = firstString(part.tool)
    const toolStatus = firstString(part.state?.status)
    const questions = Array.isArray(part.state?.input?.questions) ? part.state.input.questions : []

    if (toolName === "question" && questions.length > 0 && toolStatus !== "completed") {
      return enrichWithTaskProgress(partSessionID, {
        eventType: "question.asked",
        sessionID: partSessionID,
        cwd: resolveWorkingDirectory(partSessionID, firstString(properties.cwd), fallbackDirectory),
        questions,
      })
    }
  }

  return null
}

function describeQuestion(questions) {
  const first = Array.isArray(questions) ? questions[0] : undefined
  if (!first) return undefined

  const lines = []
  const question = firstString(first.question)
  const header = firstString(first.header)
  if (question) lines.push(question)
  else if (header) lines.push(header)

  const options = Array.isArray(first.options) ? first.options : []
  const labels = options.map((o) => firstString(o.label)).filter(Boolean)
  if (labels.length > 0) lines.push(labels.map((l) => `[${l}]`).join(" "))

  if (lines.length === 0) return undefined
  return { text: lines.join("\n"), kind: labels.length > 0 ? "decision" : "question" }
}

function toCanonicalEvent(envelope) {
  if (!envelope || !envelope.eventType) return undefined

  const base = { version: 1, agent: { name: "OpenCode" } }
  if (envelope.sessionID) base.session = { id: envelope.sessionID }
  if (envelope.cwd) base.context = { workingDirectory: envelope.cwd }

  const progress =
    envelope.taskProgressTotalCount > 0
      ? { done: envelope.taskProgressDoneCount ?? 0, total: envelope.taskProgressTotalCount }
      : undefined

  switch (envelope.eventType) {
    case "session.status": {
      const status = firstString(envelope.status)
      if (status === "busy" || status === "retry") {
        return { ...base, event: "agent.running", progress }
      }
      if (status === "idle") {
        return { ...base, event: "agent.idle", progress }
      }
      return undefined
    }
    case "session.idle":
      return { ...base, event: "agent.idle", progress }
    case "permission.asked":
    case "permission.updated":
      return {
        ...base,
        event: "agent.needs-input",
        state: {
          interaction: { kind: "approval", text: firstString(envelope.title) || "OpenCode needs your approval" },
        },
        progress,
      }
    case "permission.replied":
      return { ...base, event: "agent.input-resolved", progress }
    case "question.asked": {
      const q = describeQuestion(envelope.questions)
      return {
        ...base,
        event: "agent.needs-input",
        state: {
          interaction: { kind: q?.kind ?? "question", text: q?.text || "OpenCode is asking a question" },
        },
        progress,
      }
    }
    case "question.replied":
      return { ...base, event: "agent.input-resolved", progress }
    case "todo.updated":
      return progress ? { ...base, event: "task.progress", progress } : undefined
    default:
      return undefined
  }
}

async function forwardEnvelope(envelope) {
  if (!hasZenttyIntegration || !envelope) return

  const canonical = toCanonicalEvent(envelope)
  if (!canonical) return

  const subprocess = Bun.spawn([resolvedCliBin, "ipc", "agent-event"], {
    stdio: ["pipe", "ignore", "ignore"],
    env: process.env,
  })
  subprocess.stdin.write(`${JSON.stringify(canonical)}\n`)
  subprocess.stdin.end()
  await subprocess.exited
}

export const ZenttyOpenCodePlugin = async ({ directory }) => {
  if (!hasZenttyIntegration) {
    return {}
  }

  return {
    event: async ({ event }) => {
      const envelope = normalizeEnvelope(event, directory)
      await forwardEnvelope(envelope)
    },
  }
}
