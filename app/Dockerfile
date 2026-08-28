# syntax=docker/dockerfile:1

##########################################################
# Build stage: install production dependencies only      #
##########################################################
FROM node:22-alpine AS build
WORKDIR /app

# Install deps from the lockfile for reproducible builds
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy application source
COPY app.js ./

##########################################################
# Runtime stage: minimal, non-root image                 #
##########################################################
FROM node:22-alpine AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /app

# Apply available OS security patches, and drop npm (not needed at runtime;
# removing it also strips npm's bundled deps from image scans).
RUN apk --no-cache upgrade \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

# Copy vetted modules and source from the build stage
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/app.js ./app.js

# Run as the image's built-in unprivileged user (UID 1000 = node)
USER 1000

EXPOSE 8080

# Container healthcheck against the liveness endpoint (exec form)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:'+(process.env.PORT||8080)+'/live',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]

# Exec form so SIGTERM reaches node for graceful shutdown
CMD ["node", "app.js"]
