# Red Hat Developer Hub install and congfiguration

Documentation can be found at https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.9/html/setting_up_and_configuring_your_first_red_hat_developer_hub_instance/index

## Prepare your IT infrastructure including Red Hat OpenShift Container 

Platform and required external components, and run your first Red Hat Developer Hub (RHDH) instance in production. 

Tested on OCP `4.20.22`

### Install the Red Hat Developer Hub Operator
- Version: `1.94`
- Namespace: `rhdh-operator`

### Prepare your external services

Red Hat Developer Hub relies on external services for production use, including a PostgreSQL database, Redis cache, GitHub API access, and an identity provider. 

#### PostgreSQL

An ephemeral PostgreSQL database can be deployed using

```bash
oc -n postgresql apply -f manifests/postgresql
```

Defalut values used to make note of
- POSTGRESQL_USER: `rhdh-admin`
- POSTGRESQL_PASSWORD: `rhdh-admin`
- POSTGRESQL_DATABASE: `rhdh-db`
- ports: `5432`
- FQDN (internal DNS) - `postgres.postgresql.svc.cluster.local`

Smoketest db using FQDN

```bash
oc debug deployment/postgres -- psql "postgresql://rhdh-admin:rhdh-admin@postgres.postgresql.svc.cluster.local:5432/rhdh-db" -c "SELECT 1" 
```

expected output:

```
Starting pod/postgres-debug-ccknk ...
 ?column? 
----------
        1
(1 row)


Removing debug pod ...
```

#### Redis

An ephemeral Redis cache can be deployed using

```bash
oc -n redis apply -f manifests/redis      
```

Defalut values used to make note of
- REDIS_PASSWORD: `rhdh-admin`
- FQDN (internal DNS) - `redis.redis.svc.cluster.local`

Smoketest db using FQDN

```bash
oc debug deployment/redis -- redis-cli -h redis.redis.svc.cluster.local -a rhdh-admin SET foo bar
oc debug deployment/redis -- redis-cli -h redis.redis.svc.cluster.local -a rhdh-admin GET foo
```

#### Create a GitHub App to allow Developer Hub provisioning access the GitHub API for repository. 

Opt for a GitHub App instead of an OAuth app to use fine-grained permissions, gain more control over which repositories the application can access, and use short-lived tokens. 

Github documentation (Registering a GitHub App)
https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app

You will need to:

Homepage URL
    Enter your Developer Hub URL: `https://<my_developer_hub_domain>`
Authorization callback URL
    Enter your Developer Hub authentication backend URL: `https://<my_developer_hub_domain>/api/auth/github/handler/frame`

For this, you will need to update, bases on your cluster domain, namespace, which hasn't been created yet, so it is kind of a "chicken/egg" situation.

To find your cluster's apps domain, run

```bash
export RHDH_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}') 
export RHDH_NAMESPACE="rhdh"
export RHDH_ROUTE_NAME="backstage-developer-hub"
echo "http://$RHDH_ROUTE_NAME.$RHDH_NAMESPACE.$RHDH_DOMAIN"
echo "http://$RHDH_ROUTE_NAME.$RHDH_NAMESPACE.$RHDH_DOMAIN/api/auth/github/handler/frame"
```

Make note of:
```
App ID: 3774597
Client ID: Iv23liJlld1vs14sZfE4
Client secret:  rhdh-github-app (BW)
Private key: Downloads
```

And make a copy of `manifests/rhdh/secret.txt.template` and populate the values

```
BACKEND_SECRET=<generated-hex>
GITHUB_APP_APP_ID=<your app id>
GITHUB_APP_CLIENT_ID_INTEGRATION=<your client id>
GITHUB_APP_CLIENT_SECRET_INTEGRATION=<your client secret>
GITHUB_APP_PRIVATE_KEY=<single-line pem>
GITHUB_URL=https://github.com
GITHUB_ORG=<your org slug>
GITHUB_APP_CLIENT_ID=<same client id>
GITHUB_APP_CLIENT_SECRET=<same client secret>
```
for `GITHUB_APP_PRIVATE_KEY` generate the string from the downloaded key and use the output as the value:

```bash
awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' ~/Downloads/rhdh-integration-ll.2026-05-19.private-key.pem 
```
re `BACKEND_SECRET`
This is nothing to do with GitHub. It's an internal secret that Developer Hub uses to sign tokens for communication between the frontend and backend. You just need to generate a strong random string yourself — it's not obtained from anywhere external.

Generate one with:
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

or if you don't have Node:

```bash
openssl rand -hex 32
```

Just paste whatever it outputs as the value:

`BACKEND_SECRET=a3f9c2e1b4d8...`

#### Provisioning Dev Hub

`app-config.yaml file` is the main Developer Hub configuration file. If empty, Dev Hub willjust use default values.

To prepare a deployment with the Red Hat Developer Hub Operator on OpenShift Container Platform, you can start with an empty file, or make a copy of `app-config.yaml.template` and populate it with values

This will also contain configurations for:

- Authentication in Red Hat Developer Hub
- Authorization in Red Hat Developer Hub
- Customization
- OpenShift Container Platform integration

`dynamic-plugins.yaml` file enables plugins. 
By default, Developer Hub enables a minimal plugin set, and disables plugins that require configuration or secrets, such as the GitHub repository discovery plugin and the Role-based access control (RBAC) plugin. 

`dynamic-plugins.yaml.template` can be copied and used as a starting point.

Create the namespace (`rhdh`) for your Dev Hub instance

```bash
oc apply -f manifests/rhdh/namespace.yaml
```

Create config maps for your `app-config.yaml` and `dynamic-plugins.yaml`

```bash
oc -n rhdh create configmap my-rhdh-app-config --from-file=manifests/rhdh/app-config.yaml
oc -n rhdh create configmap dynamic-plugins-rhdh --from-file=manifests/rhdh/dynamic-plugins.yaml
```

Provision your secrets.txt file to the my-rhdh-secrets secret in the `rhdh` project
```bash
oc -n rhdh create secret generic my-rhdh-secrets --from-env-file=manifests/rhdh/secrets.txt 
```

Provision your PostgreSQL database secrets
Provision your dynamic plugins config map
Provision your RBAC policies config map 


