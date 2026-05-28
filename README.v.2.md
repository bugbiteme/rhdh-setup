# Red Hat Developer Hub — Setup and Configuration Guide

Documentation reference: https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.9/html/setting_up_and_configuring_your_first_red_hat_developer_hub_instance/index

Tested on OCP `4.20.22` with RHDH Operator `1.9.4`

---

## Overview

This guide walks through deploying a working Red Hat Developer Hub (RHDH) instance on OpenShift Container Platform (OCP) from scratch, including:

- Installing the RHDH Operator
- Deploying ephemeral PostgreSQL and Redis
- Creating and configuring a GitHub App
- Deploying and configuring the RHDH instance with GitHub authentication
- ArgoCD integration via OpenShift GitOps
- Kubernetes plugin integration
- Demo application deployment

---

## Prerequisites

- Access to an OpenShift cluster (4.16–4.21) with cluster-admin permissions
- `oc` CLI installed and logged in
- A GitHub account with permission to create GitHub Apps
- Red Hat OpenShift GitOps operator installed on the cluster

---

## Repository Structure

```
manifests/
├── operators/                      # CR-based Operator installation
│   ├── kustomization.yaml
│   └── rhdh-operator.yaml
├── postgresql/
│   └── postgresql-deploy.yaml
├── redis/
│   └── redis-deploy.yaml
├── argocd/                         # Dedicated ArgoCD instance for RHDH
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── argocd-instance.yaml
│   └── argocd-secret.yaml
├── demo-app/                       # Demo application managed by ArgoCD
│   ├── kustomization.yaml
│   ├── namespace.yaml              # Apply manually (ArgoCD namespaced mode)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   └── catalog-info.yaml
└── rhdh/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── backstage.yaml              # Backstage Custom Resource
    ├── dynamic-plugins.yaml        # Plugin configuration
    ├── dynamic-plugins-pvc.yaml    # PVC for plugin caching
    ├── app-config.yaml             # Main RHDH configuration
    ├── app-config.yaml.template    # Template to copy from
    ├── secrets.txt.template        # Secrets template (copy to secrets.txt)
    └── secrets.txt                 # Your secrets (never commit this)
```

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

> **Alternative: CR-based Operator install**
> Instead of using the web console, you can install the Operator declaratively:
> ```bash
> oc apply -k manifests/operators/
> ```

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
| Authorization callback URL | `https://<rhdh-url>/api/auth/github/handler/frame` |
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

> **Important:** Make sure your GitHub org membership visibility is set to **Public** at `https://github.com/orgs/<your-org>/people`. Private membership is not visible to the GitHub App and will prevent user import.

---

## Step 4 — Prepare Secrets

### Generate a Backend Secret

This is an internal secret used by RHDH to sign tokens between frontend and backend:

```bash
openssl rand -hex 32
```

### Get the Kubernetes cluster CA

```bash
oc get configmap kube-root-ca.crt -n rhdh -o jsonpath='{.data.ca\.crt}' | base64 -w 0
```

### Create a Kubernetes service account for RHDH

```bash
oc create serviceaccount rhdh-kubernetes -n rhdh

oc create clusterrolebinding rhdh-kubernetes \
  --clusterrole=view \
  --serviceaccount=rhdh:rhdh-kubernetes

oc adm policy add-role-to-user view \
  system:serviceaccount:rhdh:rhdh-kubernetes \
  -n rhdh-demo

oc create token rhdh-kubernetes -n rhdh --duration=8760h
```

### Create secrets.txt

```bash
cp manifests/rhdh/secrets.txt.template manifests/rhdh/secrets.txt
```

Edit `manifests/rhdh/secrets.txt` and populate all values. **No blank lines, no quotes, one `KEY=value` per line:**

```
BACKEND_SECRET=<generated-hex>
GITHUB_APP_APP_ID=<your app id>
GITHUB_APP_CLIENT_ID_INTEGRATION=<your client id>
GITHUB_APP_CLIENT_SECRET_INTEGRATION=<your client secret>
GITHUB_APP_PRIVATE_KEY=<single-line pem from awk command above>
GITHUB_URL=https://github.com
GITHUB_ORG=<your github org slug>
GITHUB_APP_CLIENT_ID=<same client id as above>
GITHUB_APP_CLIENT_SECRET=<same client secret as above>
RHDH_URL=https://backstage-rhdh-instance-rhdh.apps.<your-cluster-domain>
REDIS_URL=redis://:rhdh-admin@redis.redis.svc.cluster.local:6379
POSTGRES_HOST=postgres.postgresql.svc.cluster.local
POSTGRES_PORT=5432
POSTGRES_USER=rhdh-admin
POSTGRES_PASSWORD=rhdh-admin
POSTGRES_DATABASE=rhdh-db
ARGOCD_URL=https://rhdh-gitops-server-rhdh-gitops.apps.<your-cluster-domain>
ARGOCD_USERNAME=developer-hub
ARGOCD_PASSWORD=d3v3l0p3rs
K8S_CLUSTER_NAME=openshift
K8S_CLUSTER_URL=https://kubernetes.default.svc
K8S_CLUSTER_TOKEN=<token from oc create token above>
K8S_CLUSTER_CA=<base64 CA from kube-root-ca.crt>
```

> **Note:** `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_CLIENT_SECRET` are the same values as their `_INTEGRATION` counterparts — both are needed because the config uses them in different contexts (catalog integration vs user authentication).

> **Critical:** Use `--from-env-file` (not `--from-file`) when creating the secret, or env vars won't be injected correctly. Blank lines in the file will cause parsing to stop at that point.

> **Never commit `secrets.txt` to git.** It is in `.gitignore` by default.

---

## Step 5 — Deploy ArgoCD

Deploy a dedicated ArgoCD instance for RHDH in the `rhdh-gitops` namespace:

```bash
oc apply -k manifests/argocd/
```

Wait for all pods to come up:

```bash
oc get pods -n rhdh-gitops -w
```

Get the route and verify you can log in with `developer-hub` / `d3v3l0p3rs`:

```bash
oc get route rhdh-gitops-server -n rhdh-gitops -o jsonpath='{.spec.host}'
```

> **Note:** The ArgoCD instance runs in namespaced mode and cannot create cluster-level Namespace resources. Apply target namespaces separately with the `argocd.argoproj.io/managed-by: rhdh-gitops` label.

---

## Step 6 — Deploy RHDH

### Create namespace, ConfigMaps, and Secret

```bash
oc apply -f manifests/rhdh/namespace.yaml

oc -n rhdh create configmap my-rhdh-app-config \
  --from-file=manifests/rhdh/app-config.yaml

oc -n rhdh create configmap dynamic-plugins-rhdh \
  --from-file=manifests/rhdh/dynamic-plugins.yaml

oc -n rhdh create secret generic my-rhdh-secrets \
  --from-env-file=manifests/rhdh/secrets.txt
```

Verify all secret keys were parsed correctly (you should see individual key names, not `secrets.txt`):

```bash
oc get secret my-rhdh-secrets -n rhdh -o jsonpath='{.data}' | \
  python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]"
```

### Deploy with Kustomize

```bash
oc apply -k manifests/rhdh/
```

This deploys the dynamic plugins PVC and the Backstage Custom Resource. The namespace already exists from the previous step — Kustomize will skip it without error.

---

## Step 7 — Deploy Demo Application

Create the target namespace manually (required due to ArgoCD namespaced mode):

```bash
oc apply -f manifests/demo-app/namespace.yaml
```

Create the ArgoCD Application:

```bash
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: rhdh-gitops
  labels:
    app.kubernetes.io/name: demo-app
spec:
  project: default
  source:
    repoURL: https://github.com/bugbiteme/rhdh-setup.git
    targetRevision: main
    path: manifests/demo-app
  destination:
    server: https://kubernetes.default.svc
    namespace: rhdh-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

Grant the RHDH Kubernetes service account access to the demo namespace:

```bash
oc adm policy add-role-to-user view \
  system:serviceaccount:rhdh:rhdh-kubernetes \
  -n rhdh-demo
```

---

## Step 8 — Verify

Watch pods come up:

```bash
oc get pods -n rhdh -w
```

You should see one backstage pod with no local PostgreSQL pod (`enableLocalDb: false`).

Check logs for a clean startup:

```bash
oc logs -f -n rhdh -c backstage-backend \
  $(oc get pods -n rhdh -o name | grep "backstage-rhdh-instance" | head -1)
```

A healthy startup ends with:

```
Plugin initialization complete, newly initialized: 'healthcheck', 'app', 'catalog', ...
```

Verify GitHub org sync ran successfully:

```bash
oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend | \
  grep -i "GithubMultiOrg\|Read.*GitHub"
```

You should see:
```
Read 1 GitHub users and 1 GitHub groups
```

Navigate to your RHDH URL and sign in with GitHub. Verify:
- **Catalog** shows `demo-app` component
- **CD tab** on `demo-app` shows ArgoCD deployment status
- **Kubernetes tab** on `demo-app` shows cluster resources


K8 plugin notes:


---

## Configuration Reference

### app-config.yaml

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
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
      database: ${POSTGRES_DATABASE}
    pluginDivisionMode: schema

auth:
  environment: development
  providers:
    github:
      development:
        clientId: ${GITHUB_APP_CLIENT_ID}
        clientSecret: ${GITHUB_APP_CLIENT_SECRET}
        signIn:
          resolvers:
            - resolver: usernameMatchingUserEntityName

catalog:
  locations:
    - type: url
      target: https://github.com/bugbiteme/rhdh-setup/blob/main/manifests/demo-app/catalog-info.yaml
      rules:
        - allow: [Component]
  providers:
    githubOrg:
      id: githuborg
      githubUrl: ${GITHUB_URL}
      orgs: ["${GITHUB_ORG}"]
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

argocd:
  appLocatorMethods:
    - type: config
      instances:
        - name: rhdh-gitops
          url: ${ARGOCD_URL}
          username: ${ARGOCD_USERNAME}
          password: ${ARGOCD_PASSWORD}

kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - name: ${K8S_CLUSTER_NAME}
          url: ${K8S_CLUSTER_URL}
          authProvider: serviceAccount
          skipTLSVerify: true
          skipMetricsLookup: true
          serviceAccountToken: ${K8S_CLUSTER_TOKEN}
          caData: ${K8S_CLUSTER_CA}
```

### dynamic-plugins.yaml

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-github-org-dynamic
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-community-plugin-rbac
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-community-plugin-redhat-argocd
    disabled: true
  - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes
    disabled: false
  - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd-backend:bs_1.45.3__1.0.2
    disabled: false
  - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd:bs_1.45.3__2.4.3
    disabled: false
```

### backstage.yaml (Backstage CR)

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
    enableLocalDb: false
  deployment:
    patch:
      spec:
        template:
          spec:
            volumes:
              - $patch: replace
                name: dynamic-plugins-root
                persistentVolumeClaim:
                  claimName: dynamic-plugins-root
```

### demo-app catalog-info.yaml

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: demo-app
  description: Demo application for RHDH integration testing
  annotations:
    argocd/app-name: demo-app
    backstage.io/kubernetes-id: demo-app
spec:
  type: service
  lifecycle: experimental
  owner: user:default/<your-github-username>
```

---

## Updating Configuration

When making changes to `app-config.yaml`, `dynamic-plugins.yaml`, or `secrets.txt`:

```bash
# Update a configmap
oc delete configmap my-rhdh-app-config -n rhdh
oc -n rhdh create configmap my-rhdh-app-config --from-file=manifests/rhdh/app-config.yaml

# Update dynamic plugins configmap
oc delete configmap dynamic-plugins-rhdh -n rhdh
oc -n rhdh create configmap dynamic-plugins-rhdh --from-file=manifests/rhdh/dynamic-plugins.yaml

# Update a secret
oc delete secret my-rhdh-secrets -n rhdh
oc -n rhdh create secret generic my-rhdh-secrets --from-env-file=manifests/rhdh/secrets.txt

# Restart the pod to pick up changes
oc delete pod -n rhdh -l rhdh.redhat.com/app=backstage-rhdh-instance
```

> **Note:** The dynamic plugin PVC caches installed plugins across pod restarts. The first restart after any plugin change will re-download affected plugins. Subsequent restarts will use the cache and complete in 1-2 seconds.

---

## Troubleshooting

### init container crashes in a loop (`install-dynamic-plugins`)

Check the init container logs:

```bash
oc logs -n rhdh <pod-name> -c install-dynamic-plugins --previous
```

Most likely cause: wrong plugin package name. Backend plugins require the `-dynamic` suffix, e.g. `backstage-plugin-catalog-backend-module-github-org-dynamic` not `backstage-plugin-catalog-backend-module-github-org`.

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

### `permission denied to create database`

The PostgreSQL user doesn't have permission to create databases. Add `pluginDivisionMode: schema` to the database config in `app-config.yaml` so Backstage uses schemas within the existing database instead of creating new ones.

### `Migration table is already locked`

Caused by a previous pod crashing mid-migration. Delete the pod and let it restart:

```bash
oc delete pod -n rhdh -l rhdh.redhat.com/app=backstage-rhdh-instance
```

### `Failed to sign-in, unable to resolve user identity`

Backstage authenticated with GitHub successfully but couldn't find a matching User entity in the catalog. Check:

1. Your GitHub org membership is set to **Public** at `https://github.com/orgs/<your-org>/people`
2. The `githubOrg` catalog provider ran successfully:
   ```bash
   oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend | \
     grep -i "Read.*GitHub"
   ```
3. You are using `backstage-plugin-catalog-backend-module-github-org-dynamic` (not `github-dynamic`) in `dynamic-plugins.yaml`

### `Plugin 'argocd' is already registered`

Two ArgoCD backend plugins are loaded simultaneously. The `roadiehq-backstage-plugin-argo-cd-backend-dynamic` and the OCI ArgoCD backend both register the same plugin ID. Disable the roadiehq one and use only the OCI versions:

```yaml
  - package: ./dynamic-plugins/dist/backstage-community-plugin-redhat-argocd
    disabled: true
```

### ArgoCD CD tab shows `NotImplementedError`

The ArgoCD frontend plugin requires the Kubernetes plugin to be enabled. Add both `backstage-plugin-kubernetes-backend-dynamic` and `backstage-plugin-kubernetes` to `dynamic-plugins.yaml`.

### ArgoCD `cluster level Namespace can not be managed when in namespaced mode`

The `rhdh-gitops` ArgoCD instance runs in namespaced mode and cannot create Namespace resources. Remove `namespace.yaml` from the ArgoCD application's kustomization and apply it manually with the `argocd.argoproj.io/managed-by: rhdh-gitops` label.

### `EnvConfigSource{count=1}` in startup logs

Only one env var is being substituted. The secret was likely created with `--from-file` instead of `--from-env-file`. Recreate it correctly.

### Route URL mismatch

The Operator creates the route using the CR name, not a custom name. Verify the actual route hostname before configuring the GitHub App callback URL:

```bash
oc get route -n rhdh
```

Use `https://` — the route uses `edge/Redirect` TLS termination.

### Community plugins not found (`ENOENT: no such file or directory`)

In RHDH 1.9 community plugins moved from bundled local paths to OCI images. Use the OCI path instead:

```yaml
# Wrong (RHDH 1.8 and earlier)
- package: ./dynamic-plugins/dist/backstage-community-plugin-redhat-argocd

# Correct (RHDH 1.9+)
- package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd:bs_1.45.3__2.4.3
```

See the [RHDH 1.9 Dynamic Plugins Reference](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.9/pdf/dynamic_plugins_reference/Red_Hat_Developer_Hub-1.9-Dynamic_plugins_reference-en-US.pdf) for the full migration table.

---

## Lessons Learned

- Always use `--from-env-file` when creating secrets from a key=value file — never `--from-file`
- Always include `-n <namespace>` on every `oc` command
- Backend dynamic plugin names require the `-dynamic` suffix
- Use `backstage-plugin-catalog-backend-module-github-org-dynamic` to import GitHub users/groups — `github-dynamic` only discovers repositories
- The `database` field in the Backstage CR is at `spec.database`, not `spec.application.database`
- The `default.app-config.yaml` baked into the RHDH image is loaded after your custom config and can override values — secrets must be injected as real env vars via the CR's `extraEnvs.secrets` section
- The `No configuration found for cache store 'redis'` warning is harmless
- GitHub org membership must be **Public** for the GitHub App to see org members
- The route hostname follows the pattern `<cr-name>-<namespace>.<apps-domain>` and uses HTTPS
- In RHDH 1.9 community plugins moved to OCI registry at `ghcr.io/redhat-developer/rhdh-plugin-export-overlays/` — local path references will fail with `ENOENT`
- The `catalog` key must not be duplicated in `app-config.yaml` — merge `locations` and `providers` under a single `catalog` key
- ArgoCD namespaced mode cannot manage cluster-level Namespace resources — apply namespaces separately with the `argocd.argoproj.io/managed-by` label
- The ArgoCD CD tab requires the Kubernetes plugin to be enabled as a dependency
- Add `backstage.io/kubernetes-id: <name>` to both the catalog entity annotations AND the pod template labels in the deployment for the Kubernetes tab to show resources