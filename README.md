<h1 align="center">
  IDP Backups
</h1>

<div align="center">
  <a href="https://github.com/ohsu-comp-bio/idp-backups/issues/new?assignees=&labels=bug&template=01_BUG_REPORT.md&title=bug%3A+">Report a Bug</a>
  ·
  <a href="https://github.com/ohsu-comp-bio/idp-backups/issues/new?assignees=&labels=enhancement&template=02_FEATURE_REQUEST.md&title=feat%3A+">Request a Feature</a>
  ·
  <a href="https://github.com/ohsu-comp-bio/idp-backups/discussions">Ask a Question</a>
</div>

<div align="center">
<br />

[![Project license](https://img.shields.io/github/license/ohsu-comp-bio/idp-backups.svg)](LICENSE)
[![Pull Requests welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg)](https://github.com/ohsu-comp-bio/idp-backups/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
[![Coded with love by ohsu-comp-bio](https://img.shields.io/badge/Coded%20with%20%E2%99%A5%20by-OHSU_Comp_Bio-blue)](https://github.com/ohsu-comp-bio)

</div>

- [About](#about)
- [Migration Steps (RDS)](#migration-steps-rds)
    - [1. Create New Database](#1-create-new-database)
    - [2. Create Dump Files](#2-create-dump-files)
    - [3. Restore Dump Files](#3-restore-dump-files)
    - [4. Update Helm Values](#4-update-helm-values)
    - [5. Redeploy](#5-redeploy)
    - [6. Test and Verify](#6-test-and-verify)
- [Migration Steps (Elasticsearch)](#migration-steps-elasticsearch)
    - [1. (Optional) Determine the Data Size](#1-optional-determine-the-data-size)
    - [2. Dump Indices](#2-dump-indices)
    - [3. Start AWS ES Proxy](#3-start-aws-es-proxy)
    - [4. Restore the Indices to the New Domain](#4-restore-the-indices-to-the-new-domain)
    - [5. Test and Verify](#5-test-and-verify)
- [Additional Resources](#additional-resources)

---

# About

The steps below provide a guide for creating backups of PostgreSQL databases and Elasticsearch indices, restoring them to the new environment, and ensuring everything is configured correctly.

# Migration Steps (RDS)

## 1. Create New Database

- Set up the new RDS instance in the AWS console with the appropriate configurations.

## 2. Create Dump Files

### Set Environment Variables

```sh
export DEPLOYMENT='development'
export PGHOST='<RDS ENDPOINT>'
export PGPASSWORD='<RDS PASSWORD>'
export USER='<RDS USER>'
export DB_DUMP_DIR='/tmp/$DEPLOYMENT-db-dump'
mkdir -p $DB_DUMP_DIR
```

### Dump Databases

```sh
dbs=(
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

# Loop through each database and perform the dump
for db in "${dbs[@]}"
do
  echo "Dumping: $db to $DB_DUMP_DIR/$db"
  pg_dump -h $PGHOST -U $USER -W -d $db -f "$DB_DUMP_DIR/$db"
done
```

## 3. Restore Dump Files

### Update Environment Variables

```sh
export PGHOST='<NEW RDS ENDPOINT>'
export PGPASSWORD='<NEW RDS PASSWORD>'
```

### Restore Global Objects and Roles

Restore global objects such as roles and tablespaces before restoring the individual databases:

```sh
psql -h $PGHOST -U $PGUSER -f "$DB_DUMP_DIR/$DEPLOYMENT_globals.sql"
```

### Drop and Recreate Databases

Ensure that old databases are dropped, and fresh databases are created:

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
    psql -h $PGHOST -U $PGUSER -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_$DEPLOYMENT' AND pid <> pg_backend_pid();"
    psql -h $PGHOST -U $PGUSER -c "DROP DATABASE IF EXISTS $DB_$DEPLOYMENT;"
    psql -h $PGHOST -U $PGUSER -c "CREATE DATABASE $DB_$DEPLOYMENT OWNER $PGUSER;"
done
```

### Restore Databases

Load the dump files into the newly created databases:

```sh
for DB in "${SERVICES[@]}"; do
    psql -h $PGHOST -U $PGUSER -d $DB_$DEPLOYMENT -f "$DB_DUMP_DIR/$db"
done
```

### Unset Environment Variables

Remove sensitive information from the environment:

```sh
unset PGPASSWORD
unset PGHOST
unset USER
unset DB_DUMP_DIR
```

## 4. Update Helm Values

Update your Kubernetes deployment configurations to point to the new RDS instance:

```yaml
global:
  # RDS configuration
  postgres:
    master:
      host: "<NEW RDS ENDPOINT>"
      username: "<NEW RDS USER>"
      password: "<NEW RDS PASSWORD>"
```

## 5. Redeploy

Redeploy and restart the Kubernetes deployments to apply the new configurations:

```sh
make $DEPLOYMENT

for SERVICE in "${SERVICES[@]}"; do
    kubectl rollout restart "deployment/$SERVICE-deployment"
done
```

## 6. Test and Verify

Ensure that Frontend Framework can connect to the new database and that file downloads are working as expected.

---

# Migration Steps (Elasticsearch)

## 1. (Optional) Determine the Data Size

Curl `_cat/indices` to check the total size of the Elasticsearch data:

```sh
curl -X GET "$GEN3_ELASTICSEARCH_MASTER_SERVICE_HOST/_cat/indices?v&h=index,store.size"
```

## 2. Dump Indices

```sh
export ES_ENDPOINT="<DOMAIN ENDPOINT>"
export ES_EXPORT="/tmp/staging-es-dump"
mkdir -p $ES_EXPORT

multielasticdump \
    --direction=dump \
    --includeType='data,mapping,alias' \
    --input=http://$GEN3_ELASTICSEARCH_MASTER_SERVICE_HOST:9200 \
    --output="$ES_EXPORT"
```

## 3. Start AWS ES Proxy

```sh
wget https://github.com/abutaha/aws-es-proxy/releases/download/v1.5/aws-es-proxy-1.5-linux-amd64 -O aws-es-proxy
chmod +x aws-es-proxy
./aws-es-proxy -endpoint "$ES_ENDPOINT" &

curl localhost:9200/_cat/indices
# green open .kibana_1            pXhB98GhQbahWs6CVm_wVw 1 0 1 0    5kb    5kb
# green open .opendistro_security fhNILwnQQTaHVHIq9EP0-w 1 0 9 0 70.7kb 70.7kb
```

## 4. Restore the Indices to the New Domain

Load the backed-up indices into the new domain using [multielasticdump](https://github.com/elasticsearch-dump/elasticsearch-dump?tab=readme-ov-file#multielasticdump):

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

## 5. Test and Verify

Ensure that Frontend Framework can connect to the new database and that file downloads are working as expected.

---

# Additional Resources

- **[ohsu-comp-bio/load-testing](https://github.com/ohsu-comp-bio/load-testing)**: Load testing and benchmarking of the Gen3 system with `k6`
