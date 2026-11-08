#!/usr/bin/env bash
# Sourced by terraform_backend_setup.sh and agentcore_backends.sh: resolves the Terraform state
# bucket name once, the same way for both.
#
# S3 bucket names are global, so a fixed name collides with other accounts (and with names AWS
# still reserves after a delete). The default is therefore derived from the account that is
# deploying: spbc-tfstate-<account-id>. Set TF_STATE_BUCKET to use a different name.
#
# Sets STATE_BUCKET (and ACCOUNT_ID when it had to look it up). Needs working AWS credentials
# unless TF_STATE_BUCKET is set.
if [ -n "${TF_STATE_BUCKET:-}" ]; then
    STATE_BUCKET="$TF_STATE_BUCKET"
else
    ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
    case "$ACCOUNT_ID" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) echo "No AWS credentials (aws sts get-caller-identity failed); configure them or set TF_STATE_BUCKET." >&2
           return 1 2>/dev/null || exit 1 ;;
    esac
    STATE_BUCKET="spbc-tfstate-${ACCOUNT_ID}"
fi
export STATE_BUCKET
