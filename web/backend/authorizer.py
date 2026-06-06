import json
import time
import urllib.request

import jwt
from jwt import PyJWKClient

CLIENT_ID = "814a597e-ee9f-46d1-a28e-89f9b85bb961"
DISCOVERY_URL = "https://api.account.gistory.me/.well-known/openid-configuration"
JWKS_CACHE_TTL = 3600

_jwks_client: PyJWKClient | None = None
_issuer: str | None = None
_jwks_loaded_at: float = 0.0


def _load_jwks() -> tuple[PyJWKClient, str]:
    global _jwks_client, _issuer, _jwks_loaded_at
    now = time.time()
    if _jwks_client is None or now - _jwks_loaded_at > JWKS_CACHE_TTL:
        with urllib.request.urlopen(DISCOVERY_URL, timeout=5) as resp:
            meta = json.load(resp)
        _jwks_client = PyJWKClient(meta["jwks_uri"])
        _issuer = meta["issuer"]
        _jwks_loaded_at = now
    return _jwks_client, _issuer  # type: ignore[return-value]


def _policy(principal_id: str, effect: str, resource: str, context: dict | None = None) -> dict:
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


def lambda_handler(event, _context):
    token = (event.get("queryStringParameters") or {}).get("token")
    method_arn = event.get("methodArn", "*")

    if not token:
        raise Exception("Unauthorized")

    try:
        jwks_client, issuer = _load_jwks()
        signing_key = jwks_client.get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            issuer=issuer,
            audience=CLIENT_ID,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except Exception:
        raise Exception("Unauthorized")

    return _policy(
        claims["sub"],
        "Allow",
        method_arn,
        {"userId": claims["sub"], "email": claims.get("email", "")},
    )
