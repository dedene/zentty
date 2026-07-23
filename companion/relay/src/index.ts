import { loadConfig, loadPushConfig } from './config.js';
import { createLogger } from './log.js';
import { createRelayServer } from './server.js';
import { createPushGateway } from './push/gateway.js';

// Service entry point. Loads config from the environment, starts the relay + push
// gateway, and wires graceful shutdown on SIGINT/SIGTERM.

export { loadConfig, loadPushConfig } from './config.js';
export type {
  RelayConfig,
  LogLevel,
  PushConfig,
  ApnsConfig,
  FcmConfig,
} from './config.js';
export { createRelayServer } from './server.js';
export type { RelayServerHandle } from './server.js';
export { createLogger } from './log.js';
export type { Logger } from './log.js';
export { createPushGateway } from './push/gateway.js';
export type { PushGateway, PushGatewayDeps } from './push/gateway.js';
export { PushRegistry } from './push/registry.js';
export { ApnsClient } from './push/apns.js';
export { FcmClient } from './push/fcm.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const logger = createLogger(config.logLevel);
  const pushConfig = loadPushConfig();
  const gateway = createPushGateway(pushConfig, logger);
  logger.info('push gateway', {
    apns: gateway.apns.isEnabled,
    fcm: gateway.fcm.isEnabled,
  });
  const server = createRelayServer(config, logger, gateway);
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
