#!/bin/bash

source ~/environment/env.sh


# KB documents go under electronics_payments/ — the prefix the payments KB data source syncs
aws s3 cp payments_policies_kb_faqs.txt s3://$CLOUDAGE_S3_BUCKET/electronics_payments/
echo -e "\n\nPayments Policy files successfully uploaded to S3\n"

cd ..