#!/bin/bash
set -e

# Example script to migrate databases from one RDS instance to another

# Step 1: Set up environment variables
export DEPLOYMENT='development'
export PGHOST='<OLD_RDS_ENDPOINT>'
export PGPASSWORD='<OLD_RDS_PASSWORD>'
export PGUSER='<RDS_USER>'
export DB_DUMP_DIR="/tmp/${DEPLOYMENT}-db-dump"
mkdir -p $DB_DUMP_DIR

# Step 2: Dump databases from the old RDS instance
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

for db in "${dbs[@]}"; do
  echo "Dumping: $db to $DB_DUMP_DIR/$db"
  pg_dump -h $PGHOST -U $PGUSER -d $db -f "$DB_DUMP_DIR/$db"
done

# Step 3: Update environment variables for the new RDS instance
export PGHOST='<NEW_RDS_ENDPOINT>'
export PGPASSWORD='<NEW_RDS_PASSWORD>'

# Step 4: Restore global objects and roles
psql -h $PGHOST -U $PGUSER -f "$DB_DUMP_DIR/${DEPLOYMENT}_globals.sql"

# Step 5: Drop and recreate databases on the new RDS instance
for DB in "${dbs[@]}"; do
  psql -h $PGHOST -U $PGUSER -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}_${DEPLOYMENT}' AND pid <> pg_backend_pid();"
  psql -h $PGHOST -U $PGUSER -c "DROP DATABASE IF EXISTS ${DB}_${DEPLOYMENT};"
  psql -h $PGHOST -U $PGUSER -c "CREATE DATABASE ${DB}_${DEPLOYMENT} OWNER $PGUSER;"
done

# Step 6: Restore databases from the dump files
for DB in "${dbs[@]}"; do
  psql -h $PGHOST -U $PGUSER -d "${DB}_${DEPLOYMENT}" -f "$DB_DUMP_DIR/$DB"
done

# Step 7: Unset environment variables
unset PGPASSWORD
unset PGHOST
unset PGUSER
unset DB_DUMP_DIR

# Step 8: Update Helm values and redeploy services
sed -i "s|postgres.master.host:.*|postgres.master.host: '<NEW_RDS_ENDPOINT>'|g" values.yaml
sed -i "s|postgres.master.username:.*|postgres.master.username: '<NEW_RDS_USER>'|g" values.yaml
sed -i "s|postgres.master.password:.*|postgres.master.password: '<NEW_RDS_PASSWORD>'|g" values.yaml

make $DEPLOYMENT

for SERVICE in "${dbs[@]}"; do
  kubectl rollout restart deployment/${SERVICE}-deployment
done

# Step 9: Test and verify
echo "RDS migration completed. Please test your deployment to ensure everything is working correctly."

