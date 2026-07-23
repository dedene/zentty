# Zentty companion relay. Build from the companion workspace root:
#   docker build -f relay/Dockerfile -t zentty-relay .
#
# Multi-stage: the builder installs the pnpm workspace and bundles the relay
# (plus its @zentty/wire dependency and ws) into a single self-contained ESM
# file. The runtime stage carries only that bundle and Node — zero node_modules,
# so no runtime dependencies ship in the image.

# syntax=docker/dockerfile:1

FROM node:24-alpine AS builder
WORKDIR /app
RUN corepack enable

# Manifests first for a cacheable install layer.
COPY .npmrc pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY wire/package.json ./wire/package.json
COPY relay/package.json ./relay/package.json
RUN pnpm install --frozen-lockfile

# Sources, then build wire (bundle input) and bundle the relay.
COPY wire ./wire
COPY relay ./relay
RUN pnpm --filter @zentty/wire build \
 && pnpm --filter @zentty/relay bundle

FROM node:24-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080
COPY --from=builder /app/relay/dist/server.mjs ./server.mjs
EXPOSE 8080
USER node
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1
CMD ["node", "server.mjs"]
