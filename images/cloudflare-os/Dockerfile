# syntax=docker/dockerfile:1

# Cloudflare OS — self-hosted AI productivity environment.
# Upstream: https://github.com/cloudflare/cloudflare-os (early access; runs the
# dev-mode wrangler/workerd stack, which upstream documents as try-out mode).
#
# The container serves the prebuilt frontend + all workers on :8787 and stores
# all persistent state (KV / R2 / Durable Object SQLite) under /app/.wrangler —
# mount a PVC there.

FROM node:22-bookworm-slim

# Reproducible builds: pin an upstream commit. Bump here (and the image tag) to upgrade.
ARG CLOUDFLARE_OS_REF=aedcda8b3066ff666f57ae28ecef7341d6c2dee7 # gitleaks:allow — upstream git commit, not a secret

# git: clone upstream. python3/make/g++: safety net for native npm modules.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      python3 \
      make \
      g++ \
 && rm -rf /var/lib/apt/lists/*

# Pin pnpm globally for all users (corepack shims re-download pnpm per-user at
# runtime, which is fragile in a container).
RUN npm install -g pnpm@11.17.0

WORKDIR /app
RUN git init -q . \
 && git remote add origin https://github.com/cloudflare/cloudflare-os.git \
 && git fetch -q --depth 1 origin "$CLOUDFLARE_OS_REF" \
 && git checkout -q --detach FETCH_HEAD

# Let wrangler accept non-loopback connections inside the pod (BIND_IP env).
COPY bind-ip.patch /tmp/bind-ip.patch
RUN git apply /tmp/bind-ip.patch

RUN --mount=type=cache,id=cloudflare-os-pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# Build only what the server needs at runtime (mirrors scripts/run-local.mjs).
RUN pnpm --filter @gadgets/typed-storage build \
 && pnpm --filter @gadgets/workshop-frontend exec vite build

ENV BIND_IP=0.0.0.0

RUN mkdir -p /app/.wrangler && chown -R node:node /app
USER node
EXPOSE 8787

# Equivalent to `pnpm run-local` minus install/build (already done above).
CMD ["node", "run-dev-server.js", "--serve-frontend-assets"]
