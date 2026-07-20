import { loadConfig } from './config.js';
import { createLogger } from './log.js';
import { createRelayServer } from './server.js';

// Service entry point. Loads config from the environment, starts the relay, and
// wires graceful shutdown on SIGINT/SIGTERM.

export { loadConfig } from './config.js';
export type { RelayConfig, LogLevel } from './config.js';
export { createRelayServer } from './server.js';
export type { RelayServerHandle } from './server.js';
export { createLogger } from './log.js';
export type { Logger } from './log.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const logger = createLogger(config.logLevel);
  const server = createRelayServer(config, logger);
  await server.listen();

  const shutdown = (signal: string): void => {
    logger.info('shutting down', { signal });
    void server.close().then(() => process.exit(0));
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

// Run only when invoked directly (not when imported by tests).
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error: unknown) => {
    process.stderr.write(
      `relay failed to start: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`,
    );
    process.exit(1);
  });
}
