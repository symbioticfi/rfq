# syntax=docker/dockerfile:1.7

FROM node:24.14.0-alpine3.22 AS build

WORKDIR /app

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"
ENV PONDER_TELEMETRY_DISABLED=true

RUN corepack enable && corepack prepare pnpm@10.24.0 --activate

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

ARG RFQ_DEPLOYMENT_ENV

RUN test -n "$RFQ_DEPLOYMENT_ENV"
RUN RFQ_DEPLOYMENT_ENV="$RFQ_DEPLOYMENT_ENV" node ./scripts/sync-deployment.mjs

RUN pnpm exec tsc -p tsconfig.json
RUN pnpm prune --prod

FROM node:24.14.0-alpine3.22 AS final

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=42071
ENV PONDER_TELEMETRY_DISABLED=true

COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/abis ./abis
COPY --from=build --chown=node:node /app/config ./config
COPY --from=build --chown=node:node /app/generated ./generated
COPY --from=build --chown=node:node /app/ponder.config.ts ./ponder.config.ts
COPY --from=build --chown=node:node /app/ponder.schema.ts ./ponder.schema.ts
COPY --from=build --chown=node:node /app/src ./src

RUN mkdir -p /app/.ponder && chown node:node /app /app/.ponder

USER node

EXPOSE 42071

CMD ["sh", "-c", "node node_modules/ponder/dist/esm/bin/ponder.js start --schema rfq_indexer --views-schema rfq_indexer_views --port ${PORT:-42071}"]
