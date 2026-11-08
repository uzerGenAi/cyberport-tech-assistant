#!/bin/bash

source ~/environment/env.sh

aws s3 cp menu_records.json s3://$CLOUDAGE_S3_BUCKET/menu/
echo -e "\n\nMenu items successfully uploaded to S3\n"

# KB documents go under electronics_menu/ — the prefix the menu KB data source syncs
aws s3 cp menu_items_kb_faqs.txt s3://$CLOUDAGE_S3_BUCKET/electronics_menu/
echo -e "\n\nMenu Policy files successfully uploaded to S3\n"

cd ..