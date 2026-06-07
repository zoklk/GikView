import json
import urllib.error
import urllib.request

from log_util import get_logger

logger = get_logger(__name__)

# GIST IdP access_token 은 opaque reference token 이라 오프라인 JWKS 서명검증이
# 불가하다. 매 $connect 마다 userinfo 1회 호출로 검증한다 (WS 연결은 long-lived,
# 연결 빈도 낮아 캐싱 불필요).
USERINFO_URL = "https://api.account.gistory.me/oauth/userinfo"


def _policy(
    principal_id: str, effect: str, resource: str, context: dict | None = None
) -> dict:
    doc = {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": effect,
                    "Action": "execute-api:Invoke",
                    "Resource": resource,
                }
            ],
        },
    }
    if context:
        doc["context"] = context
    return doc


def _userinfo(token: str) -> dict:
    req = urllib.request.Request(
        USERINFO_URL, headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)


def lambda_handler(event, _context):
    token = (event.get("queryStringParameters") or {}).get("token")
    method_arn = event.get("methodArn", "*")

    if not token:
        logger.warning("auth denied: missing token")
        raise Exception("Unauthorized")

    try:
        claims = _userinfo(token)
    except urllib.error.HTTPError as e:
        # 401 등 비-200 → 무효 토큰. 사유만 기록, token 자체는 절대 안 찍음.
        logger.warning("auth denied: HTTP %s", e.code)
        raise Exception("Unauthorized")
    except Exception as e:
        logger.warning("auth denied: %s: %s", type(e).__name__, e)
        raise Exception("Unauthorized")

    return _policy(
        claims["sub"],
        "Allow",
        method_arn,
        {"userId": claims["sub"], "email": claims.get("email", "")},
    )
