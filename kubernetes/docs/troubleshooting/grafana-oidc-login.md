# Grafana OIDC Login Troubleshooting

## Setup

- Grafana 12.x (kube-prometheus-stack)
- Authelia OIDC provider
- `auth.generic_oauth` with PKCE, auto_login

## Issue 1: "Login failed — User sync failed"

**Symptom**: After authenticating at Authelia and accepting consent, Grafana shows "Login failed" with "User sync failed".

**Log**:
```
logger=user.sync level=error msg="Failed to create user" error="user not found"
  auth_module=oauth_generic_oauth auth_id=<uuid>
```

### Root cause: `login_attribute_path` collides with built-in admin

If `login_attribute_path: preferred_username` and the Authelia username is `admin`, it collides with Grafana's built-in admin user (also login `admin`). Grafana can't create a new OAuth user with a taken login, and can't link to the existing one because `auth_id` doesn't match.

**Fix**: Use `email` as the login attribute:
```yaml
auth.generic_oauth:
  login_attribute_path: email
```

### Root cause: Grafana 10+ email lookup disabled by default

Since Grafana 10.0 (CVE-2023-3128), OAuth users are matched only by `auth_id` (sub claim), not email. If a user with the same email exists from a different auth method, creation fails.

**Fix**: Enable email-based lookup (safe for single-IdP homelab):
```yaml
auth:
  oauth_allow_insecure_email_lookup: true
```

## Issue 2: "Error retrieving access token payload — token is not in JWT format"

**Symptom**: Warning in Grafana logs during OAuth callback.

**Root cause**: Authelia returns opaque access tokens, not JWTs. This is expected and harmless — Grafana falls back to the ID token and UserInfo endpoint.

**Fix**: No action needed. This is a warning, not an error.

## Issue 3: Missing email/name/groups in user profile

**Symptom**: User created but email, name, or groups are empty.

**Root cause**: Authelia v4.39+ no longer includes `email`, `name`, `groups` in the ID token by default — only at the UserInfo endpoint. Grafana has a known bug (#106686) where it doesn't always query UserInfo for all claims.

**Fix**: Define a `claims_policy` in Authelia that forces claims into the ID token:
```yaml
identity_providers:
  oidc:
    claims_policies:
      grafana:
        id_token:
          - email
          - name
          - groups
          - preferred_username
    clients:
      - client_id: grafana
        claims_policy: grafana
```

## Issue 4: additionalSecrets volume mount fails

**Symptom**: Authelia pod stuck in `ContainerCreating`:
```
MountVolume.SetUp failed for volume "secret-oidc-jwks" : secret "oidc-jwks" not found
```

**Root cause**: `secret.additionalSecrets.<name>` uses the key name as the K8s Secret name. It does NOT read from the main `authelia-secret` — it expects a separate Secret named `<name>`.

**Fix**: Create a separate ExternalSecret with `target.name` matching the additionalSecrets key:
```yaml
# externalsecret-oidc-jwks.yaml
spec:
  target:
    name: oidc-jwks  # must match additionalSecrets key name
```

## Debug Checklist

```bash
# 1. Verify OIDC discovery
curl https://auth.ringbell.cc/.well-known/openid-configuration | jq .

# 2. Check ExternalSecrets synced
kubectl -n auth get externalsecret
kubectl -n observability get externalsecret

# 3. Check Authelia logs for OIDC errors
kubectl -n auth logs deploy/authelia | grep -i oidc

# 4. Check Grafana logs (enable debug temporarily)
kubectl -n observability set env deploy/kube-prometheus-stack-grafana \
  -c grafana GF_LOG_LEVEL=debug
# Try login, then:
kubectl -n observability logs -l app.kubernetes.io/name=grafana -c grafana \
  | grep -i "oauth\|user\.sync\|authn"
# Remove debug after:
kubectl -n observability set env deploy/kube-prometheus-stack-grafana \
  -c grafana GF_LOG_LEVEL-

# 5. Verify Grafana config applied
kubectl -n observability exec deploy/kube-prometheus-stack-grafana \
  -c grafana -- cat /etc/grafana/grafana.ini | grep -A 20 "auth.generic_oauth"
```
