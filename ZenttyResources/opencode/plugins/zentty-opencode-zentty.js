const agentBin = process.env.ZENTTY_AGENT_BIN
const worklaneID = process.env.ZENTTY_WORKLANE_ID
const paneID = process.env.ZENTTY_PANE_ID

const hasZenttyIntegration = Boolean(agentBin && worklaneID && paneID)
const sessionWorkingDirectories = new Map()

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (trimmed) return trimmed
    }
  }
  return undefined
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
  )

  if (eventType === "session.created" || eventType === "session.updated") {
    const cwd = firstString(properties.info?.directory)
    rememberWorkingDirectory(sessionID, cwd)
    return null
  }

  if (eventType === "session.status") {
    const cwd = resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory)
    return {
      eventType,
      sessionID,
      cwd,
      status: firstString(properties.status?.type, properties.status),
    }
  }

  if (eventType === "session.idle") {
    const cwd = resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory)
    sessionWorkingDirectories.delete(sessionID)
    return {
      eventType,
      sessionID,
      cwd,
    }
  }

  if (eventType === "permission.asked" || eventType === "permission.updated") {
    return {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
      title: firstString(properties.title, properties.permission?.title, properties.metadata?.title),
    }
  }

  if (eventType === "permission.replied") {
    return {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
    }
  }

  if (eventType === "question.asked") {
    return {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
      questions: Array.isArray(properties.questions) ? properties.questions : [],
    }
  }

  if (eventType === "question.replied") {
    return {
      eventType,
      sessionID,
      cwd: resolveWorkingDirectory(sessionID, firstString(properties.cwd), fallbackDirectory),
    }
  }

  if (eventType === "message.part.updated") {
    const part = properties.part ?? {}
    const partSessionID = firstString(part.sessionID, sessionID)
    const toolName = firstString(part.tool)
    const toolStatus = firstString(part.state?.status)
    const questions = Array.isArray(part.state?.input?.questions) ? part.state.input.questions : []

    if (toolName === "question" && questions.length > 0 && toolStatus !== "completed") {
      return {
        eventType: "question.asked",
        sessionID: partSessionID,
        cwd: resolveWorkingDirectory(partSessionID, firstString(properties.cwd), fallbackDirectory),
        questions,
      }
    }
  }

  return null
}

async function forwardEnvelope(envelope) {
  if (!hasZenttyIntegration || !envelope) return

  const subprocess = Bun.spawn([agentBin, "opencode-hook"], {
    stdio: ["pipe", "ignore", "ignore"],
    env: process.env,
  })
  subprocess.stdin.write(`${JSON.stringify(envelope)}\n`)
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
