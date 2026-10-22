"""Model settings shared by the PoC agents.

Nova Pro has no in-Region on-demand capacity in eu-central-1, so the agents call it through the
EU cross-Region inference profile (it only routes to EU Regions). Strands' BedrockModel takes the
profile ID; RetrieveAndGenerate takes the profile as a full ARN, which includes the account ID.

MODEL_ID / MODEL_ARN come from ~/environment/env.sh (setup_env.sh). Values left over from an older
env.sh (the bare model ID or the foundation-model ARN) can't be invoked in eu-central-1, so they are
replaced with a warning instead of failing on the first question.
"""
import os
import sys

import boto3

REGION = os.environ.get("REGION", "eu-central-1")

_EU_PROFILE_ID = "eu.amazon.nova-pro-v1:0"
_BARE_MODEL_ID = "amazon.nova-pro-v1:0"


def _warn(message: str) -> None:
    print(f"[model_config] WARNING: {message}", file=sys.stderr)


def _resolve_model_id() -> str:
    model_id = os.environ.get("MODEL_ID", "").strip() or _EU_PROFILE_ID
    if REGION == "eu-central-1" and model_id == _BARE_MODEL_ID:
        _warn(f"MODEL_ID={_BARE_MODEL_ID} can't be invoked on-demand in eu-central-1; "
              f"using {_EU_PROFILE_ID}. Re-run 'source setup_env.sh' to fix env.sh.")
        return _EU_PROFILE_ID
    return model_id


def _resolve_model_arn(model_id: str) -> str:
    model_arn = os.environ.get("MODEL_ARN", "").strip()
    stale = (REGION == "eu-central-1"
             and model_arn.endswith(f":foundation-model/{_BARE_MODEL_ID}"))
    if model_arn and not stale:
        return model_arn
    if stale:
        _warn("MODEL_ARN points at the Nova Pro foundation model, which can't be invoked "
              "on-demand in eu-central-1; using the EU inference profile ARN instead.")
    if not model_id.startswith(("eu.", "us.", "apac.", "global.")):
        # A plain model ID (no geo prefix) is addressed by its foundation-model ARN
        return f"arn:aws:bedrock:{REGION}::foundation-model/{model_id}"
    account_id = os.environ.get("ACCOUNT_ID", "").strip()
    if not account_id:
        try:
            account_id = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]
        except Exception as e:  # pylint: disable=broad-except
            raise RuntimeError(
                "Can't build the inference profile ARN: set ACCOUNT_ID or MODEL_ARN "
                f"(run 'source setup_env.sh'). STS lookup failed: {e}"
            ) from e
    return f"arn:aws:bedrock:{REGION}:{account_id}:inference-profile/{model_id}"


MODEL_ID = _resolve_model_id()
MODEL_ARN = _resolve_model_arn(MODEL_ID)
