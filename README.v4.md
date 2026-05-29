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
- Kubernetes and Topology plugin integration
- Tekton pipeline integration
- Demo application deployment

---

## Prerequisites

- Access to an OpenShift cluster (4.16–4.21) with cluster-admin permissions
- `oc` CLI installed and logged in
- A GitHub account with permission to create GitHub Apps
- Red Hat OpenShift GitOps operator installed on the cluster
- Red Hat OpenShift Pipelines operator installed on the cluster (for Tekton)

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
# Create the service account
oc create serviceaccount rhdh-kubernetes -n rhdh

# Grant cluster-wide view access
oc create clusterrolebinding rhdh-kubernetes \
  --clusterrole=view \
  --serviceaccount=rhdh:rhdh-kubernetes

# Grant view access to app namespaces
oc adm policy add-role-to-user view \
  system:serviceaccount:rhdh:rhdh-kubernetes \
  -n rhdh-demo

oc adm policy add-role-to-user view \
  system:serviceaccount:rhdh:rhdh-kubernetes \
  -n rest-api

# Grant access to OpenShift Route resources
oc create clusterrole route-reader \
  --verb=get,list,watch \
  --resource=routes.route.openshift.io

oc create clusterrolebinding rhdh-kubernetes-routes \
  --clusterrole=route-reader \
  --serviceaccount=rhdh:rhdh-kubernetes

# Grant access to pod logs (required for Tekton plugin)
oc create clusterrole pod-log-reader \
  --verb=get,list,watch \
  --resource=pods/log

oc create clusterrolebinding rhdh-kubernetes-pod-logs \
  --clusterrole=pod-log-reader \
  --serviceaccount=rhdh:rhdh-kubernetes
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

---

## Step 7 — Deploy Demo Application

Create the target namespace manually (required due to ArgoCD namespaced mode):

```bash
oc apply -f manifests/demo-app/namespace.yaml
oc label namespace rhdh-demo argocd.argoproj.io/managed-by=rhdh-gitops
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

---

## Step 8 — Deploy rest-api Application with Tekton Pipeline

### Overview

The `rest-api` application uses a GitOps pipeline pattern:

```
git push → Tekton: fetch → build → push image → update deployment.yaml SHA → commit to GitHub → ArgoCD detects change → deploys
```

### Repository structure

```
https://github.com/bugbiteme/rest-api
├── Dockerfile
├── catalog-info.yaml
├── code/
│   ├── main.py
│   └── requirements.txt
└── k8/
    ├── app/
    │   ├── deployment.yaml
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── pipeline.yaml
    │   └── pipelinerun.yaml
    └── gitops/
        ├── kustomization.yaml   (excludes namespace.yaml)
        ├── namespace.yaml       (apply manually)
        ├── deployment.yaml      (image SHA updated by pipeline)
        ├── service.yaml
        └── route.yaml
```

### Setup

Create the GitHub token secret for the pipeline to commit back to the repo:

```bash
oc create secret generic github-token \
  --from-literal=token=<your-github-token> \
  -n rest-api
```

Create the namespace and label it for ArgoCD:

```bash
oc apply -f k8/gitops/namespace.yaml
oc label namespace rest-api argocd.argoproj.io/managed-by=rhdh-gitops
```

Create the ArgoCD Application:

```bash
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rest-api
  namespace: rhdh-gitops
  labels:
    app.kubernetes.io/name: rest-api
spec:
  project: default
  source:
    repoURL: https://github.com/bugbiteme/rest-api.git
    targetRevision: main
    path: k8/gitops
  destination:
    server: https://kubernetes.default.svc
    namespace: rest-api
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

Apply the pipeline:

```bash
oc apply -f k8/app/pipeline.yaml
```

Trigger a pipeline run:

```bash
oc apply -f k8/app/pipelinerun.yaml
```

Watch progress:

```bash
oc get pipelinerun -n rest-api -w
```

### Pipeline design

The pipeline has four tasks: `fetch-repository` → `build` → `update-deployment` → `commit-and-push`.

The `update-deployment` task updates the image SHA in `k8/gitops/deployment.yaml` using `sed`. The `commit-and-push` task commits the change back to GitHub using a token from the `github-token` secret. ArgoCD detects the manifest change and deploys the new image automatically.

Key implementation notes:
- Uses `alpine/git` image (has git pre-installed, avoids slow `microdnf install`)
- Sets `git config --global --add safe.directory /workspace/source` before any git commands to handle ownership mismatch between the git-clone task (uid 65532) and the commit task
- Uses `[skip ci]` in the commit message to prevent infinite pipeline trigger loops
- Uses `volumeClaimTemplate` in the PipelineRun for automatic PVC provisioning per run
- Uses `taskRunTemplate.serviceAccountName: pipeline` for internal registry push permissions

---

## Step 9 — Verify

Watch pods come up:

```bash
oc get pods -n rhdh -w
```

Check logs for a clean startup:

```bash
oc logs -f -n rhdh -c backstage-backend \
  $(oc get pods -n rhdh -o name | grep "backstage-rhdh-instance" | head -1)
```

Verify GitHub org sync ran successfully:

```bash
oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend | \
  grep -i "GithubMultiOrg\|Read.*GitHub"
```

Navigate to your RHDH URL and sign in with GitHub. Verify each entity shows:

**demo-app:**
- Overview — Deployment Summary with ArgoCD info
- Topology — visual graph with Pod, Service, and Route
- CD — ArgoCD sync status and health
- Kubernetes — pod status with CPU and memory usage

**rest-api:**
- Overview — Deployment Summary with ArgoCD info
- Topology — visual graph with Pod, Service, and Route
- CD — ArgoCD sync status and health
- Kubernetes — pod status with CPU and memory usage
- CI — Tekton pipeline runs (in progress)

Watch for catalog refresh in logs:

```bash
oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend -f | \
  grep -i "Refreshed entity"
```

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
          skipMetricsLookup: false
          dashboardApp: openshift
          caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          caData: ${K8S_CLUSTER_CA}
          customResources:
            - group: 'route.openshift.io'
              apiVersion: 'v1'
              plural: 'routes'
            - group: 'tekton.dev'
              apiVersion: 'v1beta1'
              plural: 'pipelineruns'
            - group: 'tekton.dev'
              apiVersion: 'v1beta1'
              plural: 'taskruns'
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
  - package: ./dynamic-plugins/dist/backstage-community-plugin-topology
    disabled: false
  - package: ./dynamic-plugins/dist/backstage-community-plugin-tekton
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
      envs:
        - name: NODE_EXTRA_CA_CERTS
          value: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  database:
    enableLocalDb: false
  deployment:
    patch:
      spec:
        template:
          spec:
            automountServiceAccountToken: true
            serviceAccountName: rhdh-kubernetes
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
    backstage.io/kubernetes-namespace: rhdh-demo
spec:
  type: service
  lifecycle: experimental
  owner: user:default/<your-github-username>
```

### rest-api catalog-info.yaml

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: rest-api
  description: FastAPI REST API service
  annotations:
    argocd/app-name: rest-api
    backstage.io/kubernetes-id: rest-api
    backstage.io/kubernetes-namespace: rest-api
    github.com/project-slug: bugbiteme/rest-api
    janus-idp.io/tekton-enabled: 'true'
spec:
  type: service
  lifecycle: experimental
  owner: user:default/<your-github-username>
```

### Tekton pipeline.yaml

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: rest-api
  namespace: rest-api
  labels:
    app.kubernetes.io/instance: rest-api
    app.kubernetes.io/name: rest-api
    backstage.io/kubernetes-id: rest-api
spec:
  params:
  - default: rest-api
    name: APP_NAME
    type: string
  - default: https://github.com/bugbiteme/rest-api.git
    name: GIT_REPO
    type: string
  - default: main
    name: GIT_REVISION
    type: string
  - default: image-registry.openshift-image-registry.svc:5000/rest-api/rest-api
    name: IMAGE_NAME
    type: string
  - default: .
    name: PATH_CONTEXT
    type: string
  - default: bugbiteme
    name: GIT_USER_NAME
    type: string
  - default: leon.s.levy@gmail.com
    name: GIT_USER_EMAIL
    type: string
  workspaces:
  - name: workspace
  tasks:
  - name: fetch-repository
    params:
    - name: URL
      value: $(params.GIT_REPO)
    - name: REVISION
      value: $(params.GIT_REVISION)
    - name: SUBDIRECTORY
      value: ""
    - name: DELETE_EXISTING
      value: "true"
    taskRef:
      params:
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: namespace
        value: openshift-pipelines
      resolver: cluster
    workspaces:
    - name: output
      workspace: workspace
  - name: build
    params:
    - name: IMAGE
      value: $(params.IMAGE_NAME)
    - name: TLS_VERIFY
      value: "false"
    - name: CONTEXT
      value: $(params.PATH_CONTEXT)
    runAfter:
    - fetch-repository
    taskRef:
      params:
      - name: kind
        value: task
      - name: name
        value: buildah
      - name: namespace
        value: openshift-pipelines
      resolver: cluster
    workspaces:
    - name: source
      workspace: workspace
  - name: update-deployment
    params:
    - name: IMAGE_NAME
      value: $(params.IMAGE_NAME)
    - name: IMAGE_DIGEST
      value: $(tasks.build.results.IMAGE_DIGEST)
    runAfter:
    - build
    taskSpec:
      params:
      - name: IMAGE_NAME
        type: string
      - name: IMAGE_DIGEST
        type: string
      steps:
      - name: update-image
        image: alpine/git:latest
        workingDir: /workspace/source
        script: |
          #!/bin/sh
          set -e
          git config --global --add safe.directory /workspace/source
          NEW_IMAGE="$(params.IMAGE_NAME)@$(params.IMAGE_DIGEST)"
          echo "Updating image to: $NEW_IMAGE"
          sed -i "s|image:.*rest-api.*|image: $NEW_IMAGE|g" k8/gitops/deployment.yaml
          echo "Updated deployment.yaml:"
          cat k8/gitops/deployment.yaml
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: workspace
  - name: commit-and-push
    params:
    - name: GIT_USER_NAME
      value: $(params.GIT_USER_NAME)
    - name: GIT_USER_EMAIL
      value: $(params.GIT_USER_EMAIL)
    - name: GIT_REPO
      value: $(params.GIT_REPO)
    runAfter:
    - update-deployment
    taskSpec:
      params:
      - name: GIT_USER_NAME
        type: string
      - name: GIT_USER_EMAIL
        type: string
      - name: GIT_REPO
        type: string
      steps:
      - name: commit-push
        image: alpine/git:latest
        workingDir: /workspace/source
        script: |
          #!/bin/sh
          set -e
          git config --global --add safe.directory /workspace/source
          git config user.name "$(params.GIT_USER_NAME)"
          git config user.email "$(params.GIT_USER_EMAIL)"
          REPO_URL=$(echo "$(params.GIT_REPO)" | sed 's|https://|https://'"$GITHUB_TOKEN"'@|')
          git remote set-url origin $REPO_URL
          git add k8/gitops/deployment.yaml
          git commit -m "chore: update image digest [skip ci]"
          git push origin HEAD:main
        env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: github-token
              key: token
      workspaces:
      - name: source
    workspaces:
    - name: source
      workspace: workspace
```

### Tekton pipelinerun.yaml

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: rest-api-
  namespace: rest-api
  labels:
    app.kubernetes.io/instance: rest-api
    app.kubernetes.io/name: rest-api
    backstage.io/kubernetes-id: rest-api
    pipeline.openshift.io/strategy: docker
    pipeline.openshift.io/type: kubernetes
    tekton.dev/pipeline: rest-api
spec:
  params:
  - name: APP_NAME
    value: rest-api
  - name: GIT_REPO
    value: https://github.com/bugbiteme/rest-api.git
  - name: GIT_REVISION
    value: main
  - name: IMAGE_NAME
    value: image-registry.openshift-image-registry.svc:5000/rest-api/rest-api
  - name: PATH_CONTEXT
    value: .
  - name: GIT_USER_NAME
    value: bugbiteme
  - name: GIT_USER_EMAIL
    value: leon.s.levy@gmail.com
  pipelineRef:
    name: rest-api
  taskRunTemplate:
    serviceAccountName: pipeline
  timeouts:
    pipeline: 1h0m0s
  workspaces:
  - name: workspace
    volumeClaimTemplate:
      metadata:
        labels:
          tekton.dev/pipeline: rest-api
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
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

```bash
oc logs -n rhdh <pod-name> -c install-dynamic-plugins --previous
```

Most likely cause: wrong plugin package name. Backend plugins require the `-dynamic` suffix.

### `Missing required config value at 'backend.auth.externalAccess[0].options.secret' in 'env'`

```bash
oc get secret my-rhdh-secrets -n rhdh -o jsonpath='{.data}' | \
  python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]"

oc exec -n rhdh deployment/backstage-rhdh-instance -- env | grep BACKEND_SECRET
```

If the secret key is `secrets.txt`, recreate it using `--from-env-file` instead of `--from-file`.

### `permission denied to create database`

Add `pluginDivisionMode: schema` to the database config in `app-config.yaml`.

### `Migration table is already locked`

```bash
oc delete pod -n rhdh -l rhdh.redhat.com/app=backstage-rhdh-instance
```

### `Failed to sign-in, unable to resolve user identity`

1. Set GitHub org membership to **Public** at `https://github.com/orgs/<your-org>/people`
2. Verify the `githubOrg` provider ran:
   ```bash
   oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend | grep -i "Read.*GitHub"
   ```
3. Use `backstage-plugin-catalog-backend-module-github-org-dynamic` not `github-dynamic`

### `Plugin 'argocd' is already registered`

```yaml
  - package: ./dynamic-plugins/dist/backstage-community-plugin-redhat-argocd
    disabled: true
```

### ArgoCD CD tab shows `NotImplementedError`

Enable both `backstage-plugin-kubernetes-backend-dynamic` and `backstage-plugin-kubernetes`.

### ArgoCD `cluster level Namespace can not be managed when in namespaced mode`

Remove `namespace.yaml` from the ArgoCD application kustomization and apply it manually with the `argocd.argoproj.io/managed-by: rhdh-gitops` label.

### Kubernetes tab shows 0 pods / empty resources

Do not use `backstage.io/kubernetes-label-selector` unless pods have that exact label. Use only `backstage.io/kubernetes-id` and `backstage.io/kubernetes-namespace`. Ensure the pod template in `deployment.yaml` has the `backstage.io/kubernetes-id` label.

### Kubernetes tab shows TLS error (`self-signed certificate in certificate chain`)

Set `NODE_EXTRA_CA_CERTS` in the Backstage CR and enable service account token automounting:

```yaml
extraEnvs:
  envs:
    - name: NODE_EXTRA_CA_CERTS
      value: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

```yaml
deployment:
  patch:
    spec:
      template:
        spec:
          automountServiceAccountToken: true
          serviceAccountName: rhdh-kubernetes
```

### Routes not showing in Topology tab (403 error)

```bash
oc create clusterrole route-reader \
  --verb=get,list,watch \
  --resource=routes.route.openshift.io

oc create clusterrolebinding rhdh-kubernetes-routes \
  --clusterrole=route-reader \
  --serviceaccount=rhdh:rhdh-kubernetes
```

### Tekton CI tab not appearing

Ensure the `catalog-info.yaml` has the correct annotation:

```yaml
janus-idp.io/tekton-enabled: 'true'
```

Ensure `customResources` in `app-config.yaml` uses `v1beta1` not `v1` for Tekton resources:

```yaml
- group: 'tekton.dev'
  apiVersion: 'v1beta1'
  plural: 'pipelineruns'
- group: 'tekton.dev'
  apiVersion: 'v1beta1'
  plural: 'taskruns'
```

Ensure the service account has pod log permissions:

```bash
oc create clusterrole pod-log-reader \
  --verb=get,list,watch \
  --resource=pods/log

oc create clusterrolebinding rhdh-kubernetes-pod-logs \
  --clusterrole=pod-log-reader \
  --serviceaccount=rhdh:rhdh-kubernetes
```

### Tekton `commit-and-push` task fails with `fatal: not in a git directory`

The `git-clone` task runs as uid `65532` but the `commit-and-push` task runs as a different user. Set `safe.directory` before any git commands:

```bash
git config --global --add safe.directory /workspace/source
```

Use `workingDir: /workspace/source` on the step instead of `cd` in the script.

### Tekton `commit-and-push` secret not found

```bash
oc create secret generic github-token \
  --from-literal=token=<your-github-token> \
  -n rest-api
```

### Community plugins not found (`ENOENT: no such file or directory`)

In RHDH 1.9 community ArgoCD plugins moved to OCI:

```yaml
- package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd-backend:bs_1.45.3__1.0.2
- package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-argocd:bs_1.45.3__2.4.3
```

### `EnvConfigSource{count=1}` in startup logs

Secret was created with `--from-file` instead of `--from-env-file`. Recreate it correctly.

### Catalog entity takes a long time to update

Force an immediate refresh via the three-dot menu on the entity page → **Schedule Entity Refresh**. Watch logs:

```bash
oc logs -n rhdh deployment/backstage-rhdh-instance -c backstage-backend -f | \
  grep -i "Refreshed entity"
```

---

## Lessons Learned

- Always use `--from-env-file` when creating secrets — never `--from-file`
- Always include `-n <namespace>` on every `oc` command
- Backend dynamic plugin names require the `-dynamic` suffix
- Use `backstage-plugin-catalog-backend-module-github-org-dynamic` to import GitHub users/groups — `github-dynamic` only discovers repositories
- The `database` field in the Backstage CR is at `spec.database`, not `spec.application.database`
- The `default.app-config.yaml` baked into the RHDH image is loaded after your custom config — secrets must be injected as real env vars via `extraEnvs.secrets`
- The `No configuration found for cache store 'redis'` warning is harmless
- GitHub org membership must be **Public** for the GitHub App to see org members
- The route hostname follows the pattern `<cr-name>-<namespace>.<apps-domain>` and uses HTTPS
- In RHDH 1.9 community ArgoCD plugins moved to OCI — local path references will fail
- The `catalog` key must not be duplicated in `app-config.yaml`
- ArgoCD namespaced mode cannot manage cluster-level Namespace resources
- The ArgoCD CD tab requires the Kubernetes plugin as a dependency
- Add `backstage.io/kubernetes-id` to both the catalog entity annotations AND the pod template labels in the deployment
- Do not add `backstage.io/kubernetes-label-selector` to `catalog-info.yaml` unless the pods have that exact label — it overrides the default selector
- `skipTLSVerify: true` alone is insufficient for self-signed certs — use `NODE_EXTRA_CA_CERTS` pointing to the mounted CA file
- `customResources` apiVersion for Routes should be just `v1` not the full group/version
- `customResources` apiVersion for Tekton resources must be `v1beta1` not `v1`
- The `view` ClusterRole does not include OpenShift Route resources — create a separate `route-reader` ClusterRole
- The Tekton plugin requires a separate `pod-log-reader` ClusterRole for viewing logs
- Service and Route resources need the `backstage.io/kubernetes-id` label to appear in the Topology tab
- `K8S_CLUSTER_CA` must be the base64-encoded CA certificate from `kube-root-ca.crt`, not a service account JWT token
- The Tekton CI tab requires `janus-idp.io/tekton-enabled: 'true'` in `catalog-info.yaml`
- Use `alpine/git` image in pipeline tasks instead of `ubi-minimal` + `microdnf install git` to avoid slow package installation on every run
- The `git-clone` task runs as uid `65532` — always set `safe.directory` before git commands in subsequent tasks
- Use `workingDir:` in pipeline step specs instead of `cd` in scripts
- Use `generateName` not `name` in PipelineRun manifests to allow multiple runs
- Use `[skip ci]` in pipeline commit messages to prevent infinite pipeline trigger loops
- Separate CI (pipeline) and CD (ArgoCD) — pipeline updates the image SHA in the gitops manifest, ArgoCD deploys it