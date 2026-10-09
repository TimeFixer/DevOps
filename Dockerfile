# syntax=docker/dockerfile:1
FROM node:22-bookworm AS base
WORKDIR /app
# Системные библиотеки для Chromium
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
    libasound2 && \
    rm -rf /var/lib/apt/lists/*

FROM base AS builder
COPY package*.json ./
# Кэш для npm зависимостей
RUN --mount=type=cache,target=/root/.npm npm ci

FROM base AS final
WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules

RUN npx playwright install chromium

COPY src/ ./src/

RUN mkdir -p /app/out
CMD ["node", "src/index.js"]