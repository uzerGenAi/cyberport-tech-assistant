"""GET /promotions for the SPBC Tech Assistant (HTTP API, IAM-authorized).

Promotions come from a JSON file (a list of promotion objects) that an admin uploads to S3:
s3://$PROMOTIONS_BUCKET/$PROMOTIONS_KEY. Uploading a new file is all it takes to change what the
agents see; no Terraform run or redeploy is needed. To announce "no promotions", upload [].

By default only promotions whose validity window contains today's date (UTC) are returned;
?status=all returns every promotion with its status.

Responses:
  200 + [..]  the file was read; the list is empty when nothing is active today.
  503 + {..}  the file could not be read or is not valid and no earlier good copy is available.
              A 503 means "could not check", which the agent must not present as "no promotions".

Without PROMOTIONS_BUCKET the copy bundled with the function (promos_records.json, copied from
2_data_strategy/promos/ at deploy time) is served instead (local runs, tests).
"""
import json
import logging
import os
import time
from datetime import date, datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_BUNDLED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "promos_records.json")
_BUCKET = os.environ.get("PROMOTIONS_BUCKET", "").strip()
_KEY = os.environ.get("PROMOTIONS_KEY", "promotions/promos_records.json").strip()
# How long a copy read from S3 is reused. Keeps S3 calls low and bounds how long an upload takes to show.
_CACHE_SECONDS = int(os.environ.get("PROMOTIONS_CACHE_SECONDS", "60"))

_s3 = None
# Last good copy: {"data": [...], "loaded_at": monotonic seconds}. Lives as long as the warm container.
_cache = {"data": None, "loaded_at": 0.0}


class PromotionsUnavailable(Exception):
    """The promotions file could not be read or is not a valid list."""


def _client():
    global _s3
    if _s3 is None:
        import boto3
        from botocore.config import Config

        # Short timeouts: the Lambda has 5 s and the API integration 6 s
        _s3 = boto3.client(
            "s3",
            config=Config(connect_timeout=1, read_timeout=1, retries={"max_attempts": 2, "mode": "standard"}),
        )
    return _s3


if _BUCKET:
    # Import boto3 and build the client while the container initialises, so a cold start does
    # not eat into the 5 s the first request has
    _client()


def _parse(raw: bytes) -> list:
    """Parse the promotions file; it must be a JSON list of objects."""
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise PromotionsUnavailable(f"promotions file is not valid JSON: {exc}") from exc
    if not isinstance(data, list) or not all(isinstance(item, dict) for item in data):
        raise PromotionsUnavailable("promotions file must be a JSON list of promotion objects")
    return data


def _load_promotions() -> list:
    """Return the promotions list: S3 copy (cached), the last good copy on failure, or the bundled file."""
    if not _BUCKET:
        with open(_BUNDLED_FILE, "rb") as handle:
            return _parse(handle.read())

    now = time.monotonic()
    if _cache["data"] is not None and now - _cache["loaded_at"] < _CACHE_SECONDS:
        return _cache["data"]

    try:
        body = _client().get_object(Bucket=_BUCKET, Key=_KEY)["Body"].read()
        data = _parse(body)
    except Exception as exc:  # network, permission, missing key or bad content
        if _cache["data"] is not None:
            logger.error("Could not refresh s3://%s/%s (%s); serving the last good copy", _BUCKET, _KEY, exc)
            return _cache["data"]
        logger.error("Could not read s3://%s/%s: %s", _BUCKET, _KEY, exc)
        raise PromotionsUnavailable(str(exc)) from exc

    _cache["data"] = data
    _cache["loaded_at"] = now
    return data


def _status(promotion: dict, today: date) -> str:
    """Return active, upcoming, expired or invalid for one promotion."""
    try:
        start = date.fromisoformat(promotion["valid_from"])
        end = date.fromisoformat(promotion["valid_to"])
    except (KeyError, TypeError, ValueError):
        return "invalid"
    if today < start:
        return "upcoming"
    if today > end:
        return "expired"
    return "active"


def _response(status_code: int, body, cacheable: bool = True) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": f"max-age={_CACHE_SECONDS}" if cacheable else "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, _context):
    """Lambda entry point (API Gateway HTTP API, payload format 2.0)."""
    params = (event or {}).get("queryStringParameters") or {}
    include_all = params.get("status") == "all"
    today = datetime.now(timezone.utc).date()

    try:
        all_promotions = _load_promotions()
    except PromotionsUnavailable:
        return _response(503, {"error": "Promotions are temporarily unavailable"}, cacheable=False)

    promotions = []
    for promotion in all_promotions:
        status = _status(promotion, today)
        if status == "invalid":
            logger.warning("Skipping promotion with invalid dates: %s", promotion.get("title"))
            continue
        if include_all or status == "active":
            promotions.append({**promotion, "status": status})

    logger.info("Returning %d promotion(s) (include_all=%s, date=%s)",
                len(promotions), include_all, today.isoformat())
    return _response(200, promotions)
