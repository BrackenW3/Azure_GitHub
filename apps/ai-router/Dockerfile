# =============================================================================
# Dockerfile — willbracken AI Router Container App
# Registry target: ghcr.io/willbracken/ai-router or Azure Container Registry
#
# Build:
#   docker build -t ai-router:latest .
#
# Run locally (with Azure CLI logged in for DefaultAzureCredential):
#   docker run -p 3000:3000 \
#     -e AZURE_APP_CONFIG_ENDPOINT=https://willbracken-config-ihe42a.azconfig.io \
#     -e APPLICATIONINSIGHTS_CONNECTION_STRING=<your-conn-string> \
#     ai-router:latest
# =============================================================================

FROM node:20-alpine AS deps

WORKDIR /app

# Install production deps only
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev && npm cache clean --force

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Security: run as non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy deps and source
COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./

# Owned by appuser
RUN chown -R appuser:appgroup /app
USER appuser

EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000

# Graceful startup — matches Container Apps health probe default path /health
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
