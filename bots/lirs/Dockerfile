# Counta's LIRS e-Tax bot, for Cloud Run. Playwright's own image carries Chromium and everything it needs.
FROM mcr.microsoft.com/playwright:v1.56.0-noble
WORKDIR /app
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 NODE_ENV=production
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --include=dev --no-audit --no-fund
COPY src ./src
RUN npx tsc -p tsconfig.json && npm prune --omit=dev
# Playwright's image has an unprivileged user; the bot runs as it.
USER pwuser
ENV PORT=8080
EXPOSE 8080
CMD ["node", "dist/src/server.js"]
