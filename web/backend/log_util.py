import logging
import os

# 기본 WARNING → 정상 트래픽 로깅 0. 디버깅 시 env LOG_LEVEL=INFO.
_LEVEL = os.environ.get("LOG_LEVEL", "WARNING").upper()


def get_logger(name: str) -> logging.Logger:
    """런타임 root 핸들러 재사용(핸들러 추가 금지 — 중복 출력). 레벨만 env 제어."""
    logger = logging.getLogger(name)
    logger.setLevel(_LEVEL)
    return logger
