# syntax=docker/dockerfile:1
FROM node:22-bookworm AS deps
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-bookworm AS runtime
WORKDIR /app
ENV NODE_ENV=production

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* 

COPY package.json package-lock.json ./
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src

RUN mkdir -p /app/out
CMD ["node", "src/index.js"]