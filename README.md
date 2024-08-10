# Overview

Scripts and steps for the migration of PostgreSQL databases and Elasticsearch indices from an older environment to a new environment on AWS.

The steps below provide a guide for creating backups, restoring  them to the new environment, and ensuring everything is configured correctly.

## Backup and Migration Steps

### Backup Steps (RDS)

1. **Create New Database in AWS Console**:
    - Set up the new RDS instance in the AWS console with the appropriate configurations.

2. **Create Database Dump Files from Old Database**:
    - Use `pg_dumpall` and `pg_dump` to generate the necessary dump files, including global objects, roles, and individual databases.

3. **Restore Database Dump Files to New Database**:
    - Reset the databases in the new environment by dropping existing databases and restoring from the dump files.

4. **Update PostgreSQL Values in `values.yaml`**:
    - Update your Kubernetes deployment configurations to point to the new RDS instance.

5. **Redeploy to Target the New Database**:
    - Use `kubectl` to redeploy your services with the updated configurations.

6. **Test Logging In and Downloading Files**:
    - Ensure that the application can connect to the new database and that all functionalities are working as expected.

### Detailed Commands for RDS Migration

#### 1. Set Up Environment Variables

```sh
export DEPLOYMENT='staging'
export NEW_HOST="$DEPLOYMENT-postgres.czyvh9aiqz6s.us-west-2.rds.amazonaws.com"
export NEW_USER="postgres"
export PGPASSWORD='example-password'
export DB_EXPORT="/tmp/$DEPLOYMENT-db-dump"
mkdir -p $ES_EXPOR
```

#### 2. Restore Global Objects and Roles

Restore global objects such as roles and tablespaces before restoring the individual databases.

```sh
psql -h $NEW_HOST -U $NEW_USER -f "$DB_EXPORT/$DEPLOYMENT_globals.sql"
```

#### 3. Drop and Recreate Databases

Ensure that old databases are dropped, and fresh databases are created.

```sh
SERVICES=(
    arborist
    audit
    fence
    indexd
    metadata
    peregrine
    requestor
    sheepdog
    wts
)

for DB in "${SERVICES[@]}"; do
    psql -h $NEW_HOST -U $NEW_USER -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_$DEPLOYMENT' AND pid <> pg_backend_pid();"
    psql -h $NEW_HOST -U $NEW_USER -c "DROP DATABASE IF EXISTS $DB_$DEPLOYMENT;"
    psql -h $NEW_HOST -U $NEW_USER -c "CREATE DATABASE $DB_$DEPLOYMENT OWNER $NEW_USER;"
done
```

#### 4. Restore Each Database from the Dump Files

Load the dump files into the newly created databases.

```sh
for DB in "${SERVICES[@]}"; do
    psql -h $NEW_HOST -U $NEW_USER -d $DB_$DEPLOYMENT -f "$DB_EXPORT/$db"
done
```

#### 5. Unset Environment Variables

Remove sensitive information from your environment.

```sh
unset PGPASSWORD
unset NEW_HOST
unset NEW_USER
unset DB_EXPORT
```

#### 6. Redeploy Services

Restart the Kubernetes deployments to apply the new configurations.

```sh
for SERVICE in "${SERVICES[@]}"; do
    kubectl rollout restart "deployment/$SERVICE-deployment"
done
```

### Backup Steps (Elasticsearch)

The steps below guide you through the process of migrating Elasticsearch
indices from an old domain to a new, smaller domain on AWS using the
`elasticsearch-dump` tool.

1. **Determine the Total Size of Data in the Old Domain**:

- Use the `_cat/indices` API to check the total size of your Elasticsearch data.

```sh
curl -X GET "http://<old-elasticsearch-endpoint>/_cat/indices?v&h=index,store.size"
```

2. **Create a Backup of All Indices**:

- Use `elasticsearch-dump` to back up all indices from the old domain.

```sh
export NEW_ENDPOINT="https://vpc-staging-domain-46eebau2il7sslb6o5oulpd2bi.us-west-2.es.amazonaws.com"
export ES_EXPORT="/tmp/staging-es-dump"
mkdir -p $ES_EXPORT

multielasticdump \
    --direction=dump \
    --includeType='data,mapping,alias' \
    --input=http://$GEN3_ELASTICSEARCH_MASTER_SERVICE_HOST:9200 \
    --output="$ES_EXPORT"
```
            
3. **Set Up AWS ES Proxy for New Domain**:

- Download and set up `aws-es-proxy` to facilitate communication with the new Elasticsearch domain.

```sh
wget https://github.com/abutaha/aws-es-proxy/releases/download/v1.5/aws-es-proxy-1.5-linux-amd64
chmod +x aws-es-proxy-1.5-linux-amd64
aws-es-proxy -endpoint "$NEW_ENDPOINT"

# In another window
curl localhost:9200/_cat/indices
# green open .kibana_1            pXhB98GhQbahWs6CVm_wVw 1 0 1 0    5kb    5kb
# green open .opendistro_security fhNILwnQQTaHVHIq9EP0-w 1 0 9 0 70.7kb 70.7kb
```

4.  **Restore the Indices to the New Domain**:

- Load the backed-up indices into the new domain using `elasticsearch-dump`.

```sh
multielasticdump \
  --direction=load \
  --includeType='data,mapping,alias' \
  --input="$ES_EXPORT" \
  --output=http://localhost:9200

curl localhost:9200/_cat/indices
# yellow open fhir                                    -es-HgrORbWFAceM9HHkQQ 5 1   0 0    1kb    1kb
# yellow open gen3.aced.io_file-array-config_0        61vCR5wRQEGBLw0TtGiRQA 5 1   1 0  5.2kb  5.2kb
# yellow open .kibana_2                               hsuSxgKMSE2pvRUcMyCBRA 5 1   0 0    1kb    1kb
# green  open .kibana_1                               pXhB98GhQbahWs6CVm_wVw 1 0   1 0    5kb    5kb
# green  open .opendistro_security                    fhNILwnQQTaHVHIq9EP0-w 1 0   9 0 70.7kb 70.7kb
# yellow open gen3.aced.io_observation-array-config_0 YYw5jqV1SjOdYGXK2ftrtQ 5 1   1 0  5.1kb  5.1kb
# yellow open default-commons-index                   5PhyJg_3SVOvJZpVAbNptQ 5 1   5 0 64.2kb 64.2kb
# yellow open default-commons-info-index              FPW8bLQqSsKwSmjBFYlGVQ 5 1  26 0 17.1kb 17.1kb
# yellow open gen3.aced.io_file_0                     YCzHI5pcS8yxe1M3NA2NAA 5 1 971 0  1.6mb  1.6mb
# yellow open gen3.aced.io_observation_0              OiXqJSJHR4SbmkwcEYkZbA 5 1   0 0    1kb    1kb
# yellow open gen3.aced.io_patient_0                  irvIWySsSg2TVpKO91D_jw 5 1  13 0   34kb   34kb
# yellow open default-commons-config-index            -2yTyNV6QQuAPYSK9fyLYw 5 1   1 0  4.2kb  4.2kb
# yellow open gen3.aced.io_patient-array-config_0     PUJKLsY8RPW191Mnzed-9Q 5 1   1 0  4.8kb  4.8kb
```
            
### Additional Resources    

- **[ohsu-comp-bio/load-testing](https://github.com/ohsu-comp-bio/load-testing)**: Load testing and benchmarking of the Gen3 system with `k6`
