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

#### Create a GitHub App to allow Developer Hub to access the GitHub API for repository. Opt for a GitHub App instead of an OAuth app to use fine-grained permissions, gain more control over which repositories the application can access, and use short-lived tokens. 