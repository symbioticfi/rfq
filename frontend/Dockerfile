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
ARG VITE_API_URL
ARG VITE_PRIVY_APP_ID
ARG VITE_WALLET_RPC_URL
ARG VITE_WALLET_CHAIN_NAME

RUN test -n "$RFQ_DEPLOYMENT_ENV"
RUN VITE_DEPLOYMENT_ENV="$RFQ_DEPLOYMENT_ENV" node ./scripts/sync-deployment.mjs

RUN VITE_API_URL="$VITE_API_URL" \
    VITE_PRIVY_APP_ID="$VITE_PRIVY_APP_ID" \
    VITE_WALLET_RPC_URL="$VITE_WALLET_RPC_URL" \
    VITE_WALLET_CHAIN_NAME="$VITE_WALLET_CHAIN_NAME" \
    pnpm exec tsc -b
RUN VITE_API_URL="$VITE_API_URL" \
    VITE_PRIVY_APP_ID="$VITE_PRIVY_APP_ID" \
    VITE_WALLET_RPC_URL="$VITE_WALLET_RPC_URL" \
    VITE_WALLET_CHAIN_NAME="$VITE_WALLET_CHAIN_NAME" \
    pnpm exec react-router build

FROM node:24.14.0-alpine3.22 AS final

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

COPY --from=build --chown=node:node /app/build/client ./build/client
COPY --from=build --chown=node:node /app/server.mjs ./server.mjs

USER node

EXPOSE 3000

CMD ["node", "server.mjs"]
