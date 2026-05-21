# Red Hat Developer Hub — Setup and Configuration Guide

Documentation reference: https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.9/html/setting_up_and_configuring_your_first_red_hat_developer_hub_instance/index

Tested on OCP `4.20.22` with RHDH Operator `1.9.4`

---

## Overview

This guide walks through deploying a working Red Hat Developer Hub (RHDH) instance on OpenShift Container Platform (OCP) from scratch, including:

- Installing the RHDH Operator
- Deploying ephemeral PostgreSQL and Redis
- Creating and configuring a GitHub App
- Deploying and configuring the RHDH instance

---

## Prerequisites

- Access to an OpenShift cluster (4.16–4.21) with cluster-admin permissions
- `oc` CLI installed and logged in
- A GitHub account with permission to create GitHub Apps

---

## Step 1 — Install the Red Hat Developer Hub Operator

1. In the OpenShift web console, go to **Operators → OperatorHub**
2. Search for `Developer Hub` and click the **Red Hat Developer Hub Operator** card
3. Click **Install** and configure:
   - **Update channel**: `fast-1.9` (z-stream updates only; switch to `fast-1.10` manually when ready to upgrade)
   - **Installation mode**: All namespaces (default)
   - **Installed namespace**: `rhdh-operator` (recommended default)
   - **Update approval**: Automatic or Manual
4. Click **Install** and wait for the "Installed operator: ready for use" message

> **Note:** The `fast` channel includes all updates for a version and may introduce breaking changes. The `fast-1.9` channel is safer for production as it only delivers z-stream patches.

---

## Step 2 — Deploy External Services

### PostgreSQL

Deploy an ephemeral PostgreSQL instance:

```bash
oc apply -f manifests/postgresql
```

Default connection values:

| Key | Value |
|-----|-------|
| User | `rhdh-admin` |
| Password | `rhdh-admin` |
| Database | `rhdh-db` |
| Port | `5432` |
| Internal FQDN | `postgres.postgresql.svc.cluster.local` |

Smoke test:

```bash
oc debug deployment/postgres -- psql \
  "postgresql://rhdh-admin:rhdh-admin@postgres.postgresql.svc.cluster.local:5432/rhdh-db" \
  -c "SELECT 1"
```

Expected output:
```
 ?column?
----------
        1
(1 row)
```

### Redis

Deploy an ephemeral Redis instance:

```bash
oc apply -f manifests/redis
```

Default connection values:

| Key | Value |
|-----|-------|
| Password | `rhdh-admin` |
| Internal FQDN | `redis.redis.svc.cluster.local` |

Smoke test:

```bash
oc debug deployment/redis -- redis-cli \
  -h redis.redis.svc.cluster.local -a rhdh-admin SET foo bar

oc debug deployment/redis -- redis-cli \
  -h redis.redis.svc.cluster.local -a rhdh-admin GET foo
```

---

## Step 3 — Create a GitHub App

Create a single GitHub App that handles both catalog/repository integration and user authentication.

> **Chicken-and-egg situation:** The GitHub App registration requires your RHDH URL for the Homepage URL and Authorization callback URL fields. But your RHDH instance doesn't exist yet, so the route hasn't been created. You can work around this by predicting the URL from your cluster's domain — it follows a deterministic pattern based on the route name, namespace, and cluster apps domain. Run the commands below to calculate it before the instance exists.

### Determine your RHDH URL first

Before registering the GitHub App, calculate what your RHDH URL will be once deployed. Run:

```bash
export RHDH_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export RHDH_NAMESPACE="rhdh"
export RHDH_ROUTE_NAME="backstage-rhdh-instance"
echo "RHDH URL: https://$RHDH_ROUTE_NAME-$RHDH_NAMESPACE.$RHDH_DOMAIN"
echo "Auth callback: https://$RHDH_ROUTE_NAME-$RHDH_NAMESPACE.$RHDH_DOMAIN/api/auth/github/handler/frame"
```

### Register the GitHub App

Register a GitHub App at https://github.com/settings/apps/new with:

| Field | Value |
|-------|-------|
| GitHub App name | `rhdh-<GUID>` |
| Homepage URL | Your RHDH URL |
| Authorization callback URL | `http://<rhdh-url>/api/auth/github/handler/frame` |
| Webhook | Disabled (uncheck Active) |
| Repository permissions | Contents: Read-only, Commit statuses: Read-only |
| Organization permissions | Members: Read-only |
| Where can this be installed | Only on this account |

Then:
1. Go to **General → Client secrets** → click **Generate a new client secret**
2. Go to **General → Private keys** → click **Generate a private key**
3. Go to **Install App** → install on your organization

Save: **App ID**, **Client ID**, **Client Secret**, **Private Key** (downloaded `.pem` file)

Convert the private key to a single line for use in secrets:

```bash
awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' ~/Downloads/<your-key>.pem
```

---

## Step 4 — Prepare Secrets and Configuration Files

### Generate a Backend Secret

This is an internal secret used by RHDH to sign tokens between frontend and backend. Generate a strong random string:

```bash
openssl rand -hex 32
```

Or with Node:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

### Create secrets.txt

Copy the provided template and populate all values:

```bash
cp manifests/rhdh/secrets.txt.template manifests/rhdh/secrets.txt
```

Then edit `manifests/rhdh/secrets.txt`. **No blank lines, no quotes, one `KEY=value` per line:**

```
RHDH_URL=https://backstage-rhdh-instance-rhdh.apps.<your domain>.com
BACKEND_SECRET=<generated-hex>
GITHUB_APP_APP_ID=<your app id>
GITHUB_APP_CLIENT_ID_INTEGRATION=<your client id>
GITHUB_APP_CLIENT_SECRET_INTEGRATION=<your client secret>
GITHUB_APP_PRIVATE_KEY=<single-line pem from awk command above>
GITHUB_URL=https://github.com
GITHUB_ORG=<your github org slug>
GITHUB_APP_CLIENT_ID=<same client id as above>
GITHUB_APP_CLIENT_SECRET=<same client secret as above>
REDIS_URL=redis://:rhdh-admin@redis.redis.svc.cluster.local:6379
```

> **Note:** `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_CLIENT_SECRET` are the same values as their `_INTEGRATION` counterparts — both are needed because the config uses them in different contexts (catalog integration vs user authentication).

> **Critical:** Use `--from-env-file` (not `--from-file`) when creating the secret, or env vars won't be injected correctly. Blank lines in the file will cause parsing to stop at that point.

### Create app-config.yaml

Copy the provided template and populate it with your values:

```bash
cp manifests/rhdh/app-config.yaml.template manifests/rhdh/app-config.yaml
```

The file should contain:

```yaml
app:
  title: Red Hat Developer Hub
  baseUrl: ${RHDH_URL}

backend:
  auth:
    externalAccess:
      - type: legacy
        options:
          subject: legacy-default-config
          secret: ${BACKEND_SECRET}
  baseUrl: ${RHDH_URL}
  cors:
    origin: ${RHDH_URL}
  cache:
    store: redis
    connection: ${REDIS_URL}

auth:
  environment: development

catalog:
  providers:
    github:
      providerId:
        organization: ${GITHUB_ORG}
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 15 }
          initialDelay: { seconds: 15 }

integrations:
  github:
    - host: github.com
      apps:
        - appId: ${GITHUB_APP_APP_ID}
          clientId: ${GITHUB_APP_CLIENT_ID_INTEGRATION}
          clientSecret: ${GITHUB_APP_CLIENT_SECRET_INTEGRATION}
          privateKey: ${GITHUB_APP_PRIVATE_KEY}
```

### Create dynamic-plugins.yaml

Copy the provided template:

```bash
cp manifests/rhdh/dynamic-plugins.yaml.template manifests/rhdh/dynamic-plugins.yaml
```

The file should contain:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-github-dynamic
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-community-plugin-rbac
    disabled: false
```

> **Note:** Backend plugins require the `-dynamic` suffix. The documentation examples sometimes omit this, which will cause the `install-dynamic-plugins` init container to crash.

---

## Step 5 — Deploy RHDH

### Create the namespace

```bash
oc apply -f manifests/rhdh/namespace.yaml
```

Or manually:

```bash
oc create namespace rhdh
```

### Create ConfigMaps

```bash
oc -n rhdh create configmap my-rhdh-app-config \
  --from-file=manifests/rhdh/app-config.yaml

oc -n rhdh create configmap dynamic-plugins-rhdh \
  --from-file=manifests/rhdh/dynamic-plugins.yaml
```

### Create Secret

```bash
oc -n rhdh create secret generic my-rhdh-secrets \
  --from-env-file=manifests/rhdh/secrets.txt
```

Verify all keys were parsed correctly (you should see individual key names, not `secrets.txt`):

```bash
oc get secret my-rhdh-secrets -n rhdh -o jsonpath='{.data}' | \
  python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]"
```

### Create the Backstage Custom Resource

Create `manifests/rhdh/backstage-cr.yaml`:

```yaml
apiVersion: rhdh.redhat.com/v1alpha5
kind: Backstage
metadata:
  name: rhdh-instance
  namespace: rhdh
spec:
  application:
    appConfig:
      mountPath: /opt/app-root/src
      configMaps:
        - name: my-rhdh-app-config
    dynamicPluginsConfigMapName: dynamic-plugins-rhdh
    extraEnvs:
      secrets:
        - name: my-rhdh-secrets
    database:
      enableLocalDb: true
```

Apply it:

```bash
oc apply -f manifests/rhdh/backstage-cr.yaml
```

---

## Step 6 — Verify

Watch pods come up:

```bash
oc get pods -n rhdh -w
```

You should see two pods: one PostgreSQL (`backstage-psql-rhdh-instance-0`) and one backstage pod.

Check logs for a clean startup (no errors, readiness probe returning 200):

```bash
oc logs -f -n rhdh -c backstage-backend \
  $(oc get pods -n rhdh -o name | grep "backstage-rhdh-instance" | head -1)
```

A healthy startup ends with:

```
Plugin initialization complete, newly initialized: 'healthcheck', 'app', 'catalog', ...
```

And readiness probes returning `200`:

```
"GET /.backstage/health/v1/readiness HTTP/1.1" 200
```

Navigate to your RHDH URL and you should see the login page with **Guest** and **GitHub** sign-in options.

---

## Updating Configuration

When making changes to `app-config.yaml`, `dynamic-plugins.yaml`, or `secrets.txt`, use this pattern:

```bash
# Update a configmap
oc delete configmap my-rhdh-app-config -n rhdh
oc -n rhdh create configmap my-rhdh-app-config --from-file=manifests/rhdh/app-config.yaml

# Update a secret
oc delete secret my-rhdh-secrets -n rhdh
oc -n rhdh create secret generic my-rhdh-secrets --from-env-file=manifests/rhdh/secrets.txt

# Restart the pod to pick up changes
oc delete pod -n rhdh -l rhdh.redhat.com/app=backstage-rhdh-instance
```

---

## Troubleshooting

### init container crashes in a loop (`install-dynamic-plugins`)

Check the init container logs:

```bash
oc logs -n rhdh <pod-name> -c install-dynamic-plugins --previous
```

Most likely cause: wrong plugin package name. Backend plugins require the `-dynamic` suffix, e.g. `backstage-plugin-catalog-backend-module-github-dynamic` not `backstage-plugin-catalog-backend-module-github`.

### `Missing required config value at 'backend.auth.externalAccess[0].options.secret' in 'env'`

The `BACKEND_SECRET` env var isn't making it into the pod. Check:

```bash
# Verify the secret has individual keys (not 'secrets.txt' as a single key)
oc get secret my-rhdh-secrets -n rhdh -o jsonpath='{.data}' | \
  python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]"

# Verify the env var is in the pod
oc exec -n rhdh deployment/backstage-rhdh-instance -- env | grep BACKEND_SECRET
```

If the secret key is `secrets.txt`, recreate it using `--from-env-file` instead of `--from-file`.

### `Migration table is already locked`

Caused by a previous pod crashing mid-migration. Delete the pod and let it restart:

```bash
oc delete pod -n rhdh -l rhdh.redhat.com/app=backstage-rhdh-instance
```

If it persists, check that `enableLocalDb: true` is set in your Backstage CR, or connect to your PostgreSQL instance and run:

```sql
DELETE FROM knex_migrations_lock WHERE is_locked = 1;
```

### `Either organization or app must be specified`

The GitHub catalog provider is enabled but has no config. Make sure your `app-config.yaml` has the `catalog.providers.github` section with a valid `organization` value.

### `EnvConfigSource{count=1}` in startup logs

Only one env var is being substituted, meaning most secrets aren't injected. The secret was likely created with `--from-file` instead of `--from-env-file`. Recreate it correctly.

---

## Lessons Learned

- Always use `--from-env-file` when creating secrets from a key=value file
- Always include `-n <namespace>` on every `oc` command
- Backend dynamic plugin names require the `-dynamic` suffix
- The `default.app-config.yaml` baked into the RHDH image is loaded after your custom config and can override values — secrets must be injected as real env vars via the CR's `extraEnvs.secrets` section
- `enableLocalDb: true` is required unless you configure an external PostgreSQL database explicitly
- The `No configuration found for cache store 'redis' at 'backend.cache.redis'` warning is harmless — the optional `redis:` subsection is not required


---- 
Enable Dynamic Plugin Caching

Dynamic plugin caching improves the startup performance and reliability of your rhdh deployment by storing plugin packages in a persistent volume. 
This provides several benefits:

Faster deployments: Plugins are cached locally and don’t need to be downloaded when pods start

Reduced bandwidth consumption: Plugin packages are only downloaded once and reused across deployments

Improved reliability: Reduces dependency on external registries during pod startup

Better resource utilization: Reduces CPU and memory usage during plugin installation by avoiding repeated downloads

PVC required

```bash
oc -n rhdh apply -f manifests/rhdh/dynamic-plugins-pvc.yaml
```