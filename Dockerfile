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

# 1. Копируем зависимости (этот слой кэшируется, если package.json не менялся)
COPY --from=builder /app/node_modules ./node_modules

# 2. Устанавливаем браузер. 
# Мы НЕ используем здесь cache-mount, чтобы браузер гарантированно попал ВНУТРЬ образа.
# Docker BuildKit всё равно закэширует этот слой. При make clean (docker rmi) 
# слой не удаляется из кэша сборщика, поэтому при следующем make build будет статус CACHED.
RUN npx playwright install chromium

# 3. Копируем исходный код (самый нижний, часто меняющийся слой)
COPY src/ ./src/

RUN mkdir -p /app/out
CMD ["node", "src/index.js"]