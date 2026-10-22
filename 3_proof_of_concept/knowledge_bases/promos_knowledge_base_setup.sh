#!/bin/bash
set -e

source ~/environment/env.sh

REGION="${REGION:-eu-central-1}"

echo "Creating OpenSearch index for bakery promos knowledge base..."
awscurl --service aoss --region "$REGION" -H "Content-Type: application/json" -X PUT "$AOSSENDPOINT/bakery_promos_index" -d '{
  "settings": {
    "index": {
      "knn": true,
      "knn.algo_param.ef_search": 512
    }
  },
  "mappings": {
    "properties": {
      "documentid": {
        "type": "knn_vector",
        "dimension": 1024,
        "method": {
          "name": "hnsw",
          "engine": "faiss",
          "space_type": "l2"
        }
      },
      "spbc-data": {"type": "text", "index": "true"},
      "spbc-metadata": {"type": "text", "index": "false"}
    }
  }
}'

echo "Waiting 60 seconds for index propagation..."
sleep 60

export PROMOS_KNOWLEDGE_BASE_ID=$(aws bedrock-agent create-knowledge-base \
  --name spbc-promos-knowledge-base \
  --role-arn "$ROLE_ARN" \
  --region "$REGION" \
  --knowledge-base-configuration 'type=VECTOR,vectorKnowledgeBaseConfiguration={embeddingModelArn="arn:aws:bedrock:'"${REGION}"'::foundation-model/amazon.titan-embed-text-v2:0",embeddingModelConfiguration={bedrockEmbeddingModelConfiguration={dimensions=1024}}}' \
  --storage-configuration "type=OPENSEARCH_SERVERLESS,opensearchServerlessConfiguration={collectionArn='${OPENSEARCH_COLLECTION_ARN}',vectorIndexName='bakery_promos_index',fieldMapping={vectorField='documentid',textField='spbc-data',metadataField='spbc-metadata'}}" \
  | jq -r '.knowledgeBase.knowledgeBaseId') && \
echo "export PROMOS_KNOWLEDGE_BASE_ID=$PROMOS_KNOWLEDGE_BASE_ID" >> ~/environment/env.sh && \
echo "Promos Knowledge Base ID: $PROMOS_KNOWLEDGE_BASE_ID"

aws bedrock-agent create-data-source \
  --knowledge-base-id "$PROMOS_KNOWLEDGE_BASE_ID" \
  --name spbc-promos-kb-data-source \
  --region "$REGION" \
  --data-source-configuration 'type=S3,s3Configuration={bucketArn='"${OPENSEARCH_S3_BUCKET_ARN}"',inclusionPrefixes=["bakery_promos/"]}'

export PROMOS_DATA_SOURCE_ID=$(aws bedrock-agent list-data-sources \
  --knowledge-base-id "$PROMOS_KNOWLEDGE_BASE_ID" \
  --region "$REGION" \
  | jq -r '.dataSourceSummaries[0].dataSourceId') && \
echo "export PROMOS_DATA_SOURCE_ID=$PROMOS_DATA_SOURCE_ID" >> ~/environment/env.sh && \
echo "Promos Data Source ID: $PROMOS_DATA_SOURCE_ID"

ingestion_job_id=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$PROMOS_KNOWLEDGE_BASE_ID" \
  --data-source-id "$PROMOS_DATA_SOURCE_ID" \
  --region "$REGION" \
  | jq -r '.ingestionJob.ingestionJobId')
echo "Ingestion Job ID: $ingestion_job_id"
