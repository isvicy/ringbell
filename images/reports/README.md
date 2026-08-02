# reports

Tiny LAN service hosting standalone HTML reports at `https://reports.ringbell.cc/<slug>`.

- `GET /` — index page (title extracted from each file's `<title>`, newest first)
- `GET /{slug}` — serve a report (`<slug>` = `^[a-z0-9][a-z0-9-]{0,62}$`)
- `GET /api/reports` — JSON list
- `PUT /api/reports/{slug}` — publish/overwrite (Bearer token, body = HTML, max 10 MiB, atomic rename)
- `DELETE /api/reports/{slug}` — remove (Bearer token)
- `GET /healthz`

Env: `PORT` (8080), `DATA_DIR` (/data), `API_TOKEN` (required, from 1Password item
`reports` / property `api-token` via ExternalSecret; local copy at
`pass homelab/reports/api-token`).

## Build & push (no CI — manual)

```bash
cd images/reports
docker buildx build --platform linux/amd64 \
  -t harbor.ringbell.cc/library/reports:0.1.0 --push .
# verify before bumping the tag in kubernetes/apps/default/reports/app/deployment.yaml:
skopeo inspect docker://harbor.ringbell.cc/library/reports:0.1.0 \
  --creds "isvicy:$(pass show harbor/cli-secret)" | head
```

## Publish a report

```bash
scripts/publish-report.sh path/to/report.html [slug]   # slug defaults to the filename
```
