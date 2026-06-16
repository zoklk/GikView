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

# web-visibility demand 계측 (best-effort). 미설정이면 no-op → 코드 선배포 안전.
METRICS_TABLE = os.environ.get("METRICS_TABLE")
_FLUSH_INTERVAL = 30
_FLUSH_COUNT = 50

_dynamodb = boto3.resource("dynamodb")
_connections = _dynamodb.Table(CONNECTIONS_TABLE)
_rooms = _dynamodb.Table(ROOMS_TABLE)
_metrics = _dynamodb.Table(METRICS_TABLE) if METRICS_TABLE else None
# 모듈 스코프 1회 생성 → warm 요청 client/TLS 재사용 (getState 지연 제거).
_mgmt = boto3.client("apigatewaymanagementapi", endpoint_url=WS_ENDPOINT)

# warm 컨테이너 메모리 누적 + 주기 flush. 매 connect 동기 write 금지(연결 크리티컬 패스 보호).
_pending = 0
_last_flush = time.time()


def _record_connect() -> None:
    """$connect 를 메모리에 누적, 30s 또는 50건마다 카운터에 1회 flush. best-effort —
    flush 실패가 connect 응답을 막지 않도록 예외를 삼킨다."""
    global _pending, _last_flush
    if _metrics is None:
        return
    _pending += 1
    now = time.time()
    if _pending < _FLUSH_COUNT and (now - _last_flush) < _FLUSH_INTERVAL:
        return
    try:
        _metrics.update_item(
            Key={"metric": "connect"},
            UpdateExpression="ADD n :d",
            ExpressionAttributeValues={":d": _pending},
        )
        _pending = 0
        _last_flush = now
    except ClientError as e:
        # _pending 보존 → 다음 connect 에서 재시도.
        logger.warning("metrics flush failed: %s", e)


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
    _record_connect()
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
