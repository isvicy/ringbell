# cloudflare-os

Self-hosted [Cloudflare OS](https://github.com/cloudflare/cloudflare-os) — Cloudflare's open-source
"AI productivity environment" (agent workspaces + gadget apps + gatekeepers), packaged to run on
the cluster at `https://cloudflare-os.ringbell.cc`.

Upstream is **early access**: the image runs its documented try-out mode (`wrangler dev` on
workerd serving the prebuilt frontend). This is not a production-grade upstream deployment —
good enough for homelab experimentation.

- Listens on `:8787` (all interfaces via the `BIND_IP` patch — upstream `wrangler dev` is
  loopback-only).
- All state (accounts, workspaces, gadgets, KV/R2/Durable Object SQLite) lives in
  `/app/.wrangler` — backed by the `cloudflare-os-data` PVC.
- Auth: built-in username/password signup. First account you register is yours; name it
  `admin` to get admin features (upstream dev config sets `ADMINS=["admin"]`).
- LLM providers are configured per-user in the UI (settings → add provider API key). No
  secrets are needed at deploy time. Gatekeeper OAuth apps (GitHub/Google/…) are optional
  and configured later — see upstream `docs/public-server.md`.

## Build & push (no CI — manual)

```bash
cd images/cloudflare-os
docker buildx build --platform linux/amd64 \
  -t harbor.ringbell.cc/library/cloudflare-os:0.1.2 --push .
# verify before bumping the tag in kubernetes/apps/default/cloudflare-os/app/deployment.yaml:
skopeo inspect docker://harbor.ringbell.cc/library/cloudflare-os:0.1.2 \
  --creds "isvicy:$(pass show harbor/cli-secret)" | head
```

## Upgrading upstream

1. Pick a new commit from https://github.com/cloudflare/cloudflare-os
2. Update `CLOUDFLARE_OS_REF` in the `Dockerfile`; regenerate `container-compat.patch` if
   `run-dev-server.js` changed around the patch anchors (edit the same two insertions —
   `BIND_IP` arg and per-gatekeeper `BASE_URL` — against the new ref, then `git diff`).
3. Bump the image tag, rebuild/push, update `deployment.yaml`.
