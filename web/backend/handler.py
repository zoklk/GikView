import json
import os
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from log_util import get_logger

logger = get_logger(__name__)

CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]
ROOMS_TABLE = os.environ["ROOMS_TABLE"]
WS_ENDPOINT = os.environ["WS_ENDPOINT"]
CONNECTION_TTL_SECONDS = 7200

_dynamodb = boto3.resource("dynamodb")
_connections = _dynamodb.Table(CONNECTIONS_TABLE)
_rooms = _dynamodb.Table(ROOMS_TABLE)
# 모듈 스코프 1회 생성 → warm 요청 client/TLS 재사용 (getState 지연 제거).
_mgmt = boto3.client("apigatewaymanagementapi", endpoint_url=WS_ENDPOINT)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _scan_rooms() -> dict:
    state = {}
    kwargs: dict[str, Any] = {}
    while True:
        resp = _rooms.scan(**kwargs)
        for item in resp.get("Items", []):
            state[item["room_id"]] = bool(item.get("occupied", False))
        if "LastEvaluatedKey" not in resp:
            return state
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def _post(connection_id: str, payload: dict) -> None:
    try:
        _mgmt.post_to_connection(
            ConnectionId=connection_id,
            Data=json.dumps(payload).encode("utf-8"),
        )
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "GoneException":
            logger.info("stale connection cleaned: %s", connection_id)
            _connections.delete_item(Key={"connection_id": connection_id})
        else:
            raise


def _on_connect(event):
    _connections.put_item(
        Item={
            "connection_id": event["requestContext"]["connectionId"],
            "expires_at": int(time.time()) + CONNECTION_TTL_SECONDS,
        }
    )
    return {"statusCode": 200}


def _on_disconnect(event):
    _connections.delete_item(
        Key={"connection_id": event["requestContext"]["connectionId"]}
    )
    return {"statusCode": 200}


def _on_ping(event):
    _post(event["requestContext"]["connectionId"], {"type": "pong"})
    return {"statusCode": 200}


def _on_get_state(event):
    payload = {
        "type": "state",
        "rooms": _scan_rooms(),
        "timestamp": _now_iso(),
    }
    _post(event["requestContext"]["connectionId"], payload)
    return {"statusCode": 200}


_ROUTES = {
    "$connect": _on_connect,
    "$disconnect": _on_disconnect,
    "ping": _on_ping,
    "getState": _on_get_state,
}


def lambda_handler(event, _context):
    route_key = event["requestContext"]["routeKey"]
    route = _ROUTES.get(route_key)
    if route is None:
        logger.warning("unknown routeKey: %s", route_key)
        return {"statusCode": 400}
    return route(event)
