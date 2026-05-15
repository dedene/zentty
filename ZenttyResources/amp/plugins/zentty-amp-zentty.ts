// zentty-amp-plugin-v1
import type { PluginAPI } from '@ampcode/plugin'

type AmpEvent = {
	thread?: { id?: string }
	status?: string
}

type AmpContext = {
	thread?: { id?: string }
}

const cli = process.env.ZENTTY_CLI_BIN || 'zentty'

export default function (amp: PluginAPI) {
	if (!hasZenttyRoutingEnvironment()) return

	const send = async (eventName: string, event: AmpEvent, ctx: AmpContext, stopCandidate = false) => {
		const threadID = event.thread?.id || ctx.thread?.id
		if (!threadID) return

		const payload = {
			version: 1,
			event: eventName,
			agent: {
				name: 'Amp',
				pid: positiveInt(process.env.ZENTTY_AMP_PID),
			},
			session: { id: threadID },
			state: stopCandidate ? { stopCandidate: true } : undefined,
			context: {
				workingDirectory: process.env.PWD || process.cwd(),
				launch: {
					arguments: resumeArguments(),
				},
			},
		}

		try {
			const child = Bun.spawn([cli, 'ipc', 'agent-event'], {
				stdin: 'pipe',
				stdout: 'ignore',
				stderr: 'ignore',
				env: ipcEnvironment(),
			})
			child.stdin.write(JSON.stringify(payload))
			child.stdin.end()
			await child.exited
		} catch {
			// Best effort only. Amp should not be affected by Zentty IPC failures.
		}
	}

	amp.on('session.start', (event, ctx) => send('session.start', event as AmpEvent, ctx as AmpContext))
	amp.on('agent.start', (event, ctx) => send('agent.running', event as AmpEvent, ctx as AmpContext))
	amp.on('agent.end', (event, ctx) => {
		const ampEvent = event as AmpEvent
		return send('agent.idle', ampEvent, ctx as AmpContext, ampEvent.status !== 'done')
	})
}

function hasZenttyRoutingEnvironment(): boolean {
	return Boolean(
		process.env.ZENTTY_INSTANCE_SOCKET &&
			process.env.ZENTTY_WORKLANE_ID &&
			process.env.ZENTTY_PANE_ID &&
			process.env.ZENTTY_AMP_HOOKS_DISABLED !== '1',
	)
}

function ipcEnvironment(): typeof process.env {
	const env = { ...process.env }
	delete env.AMP_API_KEY
	return env
}

function resumeArguments(): string[] {
	try {
		const value = JSON.parse(process.env.ZENTTY_AMP_RESUME_ARGUMENTS_JSON || '[]')
		return Array.isArray(value) ? value.filter((item) => typeof item === 'string' && item.length > 0) : []
	} catch {
		return []
	}
}

function positiveInt(value: string | undefined): number | undefined {
	if (!value || !/^[0-9]+$/.test(value)) return undefined
	const parsed = Number(value)
	return parsed > 0 ? parsed : undefined
}
