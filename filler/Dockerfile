# syntax=docker/dockerfile:1.7

FROM node:24.14.0-alpine3.22 AS build

WORKDIR /app

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"

RUN corepack enable && corepack prepare pnpm@10.24.0 --activate

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

ARG RFQ_DEPLOYMENT_ENV

RUN test -n "$RFQ_DEPLOYMENT_ENV"
RUN RFQ_FILLER_DEPLOYMENT_ENV="$RFQ_DEPLOYMENT_ENV" node ./scripts/sync-deployment.mjs

RUN pnpm exec tsc -p tsconfig.json

FROM node:24.14.0-alpine3.22 AS final

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=42073

COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/src ./src

USER node

EXPOSE 42073

CMD ["./node_modules/.bin/tsx", "src/index.ts"]
