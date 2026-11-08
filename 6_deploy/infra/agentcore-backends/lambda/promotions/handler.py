"""GET /promotions for the SPBC Tech Assistant (HTTP API, IAM-authorized).

Serves the promotions bundled with the function (promos_records.json, copied from
2_data_strategy/promos/ at deploy time). By default only promotions whose validity window
contains today's date (UTC) are returned; ?status=all returns every promotion with its status.
"""
import json
import logging
import os
from datetime import date, datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_DATA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "promos_records.json")

with open(_DATA_FILE, encoding="utf-8") as _f:
    _PROMOTIONS = json.load(_f)


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


def _response(status_code: int, body) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "max-age=300"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, _context):
    """Lambda entry point (API Gateway HTTP API, payload format 2.0)."""
    params = (event or {}).get("queryStringParameters") or {}
    include_all = params.get("status") == "all"
    today = datetime.now(timezone.utc).date()

    promotions = []
    for promotion in _PROMOTIONS:
        status = _status(promotion, today)
        if status == "invalid":
            logger.warning("Skipping promotion with invalid dates: %s", promotion.get("title"))
            continue
        if include_all or status == "active":
            promotions.append({**promotion, "status": status})

    logger.info("Returning %d promotion(s) (include_all=%s, date=%s)",
                len(promotions), include_all, today.isoformat())
    return _response(200, promotions)
