#!/bin/bash
set -e

# Define the list of databases
dbs=(
  arborist_staging
  audit_staging
  fence_staging
  indexd_staging
  metadata_staging
  peregrine_staging
  requestor_staging
  sheepdog_staging
  wts_staging
)

# Define PostgreSQL connection details
HOST="aced-commons-staging-aurora.cluster-czyvh9aiqz6s.us-west-2.rds.amazonaws.com"
USER="postgres"
DB_EXPORT="/tmp/staging-db-dump"
mkdir -p $DB_EXPORT

# Export password for pg_dump to use
export PGPASSWORD="<PASSWORD>"

# Loop through each database and perform the dump
for db in "${dbs[@]}"
do
  echo "Dumping: $db to $DB_EXPORT/$db"
  pg_dump -h $HOST -U $USER -W -d $db -f "$DB_EXPORT/$db"
done

# Unset the password variable for security
unset PGPASSWORD

echo "Dump completed."
