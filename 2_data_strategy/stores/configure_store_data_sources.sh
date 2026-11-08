#!/bin/bash

source ~/environment/env.sh

# Load records to the RDS DB
python313 stores_load_helper_script.py
echo -e "\n\nSample stores records successfully inserted into RDS database\n"

# KB documents go under electronics_stores/ — the prefix the stores KB data source syncs
aws s3 cp store_kb_faqs.txt s3://$CLOUDAGE_S3_BUCKET/electronics_stores/
echo -e "\n\nStores Policy files successfully uploaded to S3\n"

cd ..