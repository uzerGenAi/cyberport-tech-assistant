#!/bin/bash

source ~/environment/env.sh

# KB documents go under bakery_promos/ — the prefix the promos KB data source syncs
aws s3 cp promos_kb_faqs.txt s3://$CLOUDAGE_S3_BUCKET/bakery_promos/
echo -e "\n\nPromo Policy files successfully uploaded to S3\n"

cd ..