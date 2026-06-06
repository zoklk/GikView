import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]
ROOMS_TABLE = os.environ["ROOMS_TABLE"]
WS_ENDPOINT = os.environ["WS_ENDPOINT"]

_dynamodb = boto3.resource("dynamodb")
_connections = _dynamodb.Table(CONNECTIONS_TABLE)
_rooms = _dynamodb.Table(ROOMS_TABLE)
_mgmt = boto3.client("apigatewaymanagementapi", endpoint_url=WS_ENDPOINT)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _scan_all(table, projection: str | None = None):
    kwargs = {}
    if projection:
        kwargs["ProjectionExpression"] = projection
    while True:
        resp = table.scan(**kwargs)
        for item in resp.get("Items", []):
            yield item
        if "LastEvaluatedKey" not in resp:
            return
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def _build_state() -> dict:
    return {
        item["room_id"]: bool(item.get("occupied", False))
        for item in _scan_all(_rooms)
    }


def lambda_handler(event, _context):
    has_trigger = any(
        r.get("eventName") in ("INSERT", "MODIFY")
        for r in event.get("Records", [])
    )
    if not has_trigger:
        return {"statusCode": 200}

    payload = json.dumps({
        "type": "state",
        "rooms": _build_state(),
        "timestamp": _now_iso(),
    }).encode("utf-8")

    for item in _scan_all(_connections, projection="connection_id"):
        connection_id = item["connection_id"]
        try:
            _mgmt.post_to_connection(ConnectionId=connection_id, Data=payload)
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "GoneException":
                _connections.delete_item(Key={"connection_id": connection_id})
            else:
                raise

    return {"statusCode": 200}
