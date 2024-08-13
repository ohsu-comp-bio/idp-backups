#!/bin/bash
set -e

# Example script to migrate Elasticsearch indices from one domain to another

# Step 1: Set environment variables
export ES_ENDPOINT="<OLD_ES_DOMAIN_ENDPOINT>"
export ES_EXPORT="/tmp/staging-es-dump"
mkdir -p $ES_EXPORT

# Step 2: (Optional) Determine the size of the data in the old domain
curl -X GET "$ES_ENDPOINT/_cat/indices?v&h=index,store.size"

# Step 3: Dump indices from the old Elasticsearch domain
multielasticdump \
  --direction=dump \
  --includeType='data,mapping,alias' \
  --input="http://$ES_ENDPOINT:9200" \
  --output="$ES_EXPORT"

# Step 4: Set up AWS ES proxy for the new domain
export NEW_ES_ENDPOINT="<NEW_ES_DOMAIN_ENDPOINT>"
wget https://github.com/abutaha/aws-es-proxy/releases/download/v1.5/aws-es-proxy-1.5-linux-amd64 -O aws-es-proxy
chmod +x aws-es-proxy
./aws-es-proxy -endpoint "$NEW_ES_ENDPOINT" &

# Step 5: Restore indices to the new Elasticsearch domain
multielasticdump \
  --direction=load \
  --includeType='data,mapping,alias' \
  --input="$ES_EXPORT" \
  --output=http://localhost:9200

# Step 6: Update Helm values and redeploy services
sed -i "s|esEndpoint:.*|esEndpoint: '<NEW_ES_DOMAIN_ENDPOINT>'|g" values.yaml
sed -i "s|awsAccessKeyId:.*|awsAccessKeyId: '<AWS_ACCESS_KEY>'|g" values.yaml
sed -i "s|awsSecretAccessKey:.*|awsSecretAccessKey: '<AWS_SECRET_KEY>'|g" values.yaml

make $DEPLOYMENT

kubectl rollout restart deployment/aws-es-proxy-deployment

# Step 7: Test and verify
echo "Elasticsearch migration completed. Please test your deployment to ensure everything is working correctly."

