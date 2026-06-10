import json
import urllib.error
import urllib.request

from log_util import get_logger

logger = get_logger(__name__)

# opaque access_token → 오프라인 JWKS 검증 불가. $connect 마다 userinfo 1회 호출로 검증.
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
        # 비-200 → 무효 토큰. 사유만 기록, token 값은 안 찍음.
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
