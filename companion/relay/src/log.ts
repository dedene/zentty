import type { LogLevel } from './config.js';

// Minimal leveled logger. No dependency; writes single-line JSON to stderr so a
// container log collector can parse it. `silent` disables all output (tests).

const RANK: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
  silent: 100,
};

export interface Logger {
  debug(msg: string, fields?: Record<string, unknown>): void;
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
}

export function createLogger(level: LogLevel): Logger {
  const threshold = RANK[level];
  function emit(
    lvl: Exclude<LogLevel, 'silent'>,
    msg: string,
    fields?: Record<string, unknown>,
  ): void {
    if (RANK[lvl] < threshold) {
      return;
    }
    const line = JSON.stringify({
      level: lvl,
      msg,
      ts: new Date().toISOString(),
      ...fields,
    });
    process.stderr.write(line + '\n');
  }
  return {
    debug: (m, f) => emit('debug', m, f),
    info: (m, f) => emit('info', m, f),
    warn: (m, f) => emit('warn', m, f),
    error: (m, f) => emit('error', m, f),
  };
}
