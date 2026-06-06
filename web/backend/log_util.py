import logging
import os

# 비용 메모: 기본 WARNING. happy-path 는 아무것도 안 찍으므로 정상 트래픽에서
# CloudWatch 수집량 ~0. 디버깅 시 Lambda 환경변수 LOG_LEVEL=INFO 로 올리고
# 끝나면 되돌린다(콘솔 1회, 재배포 불필요).
_LEVEL = os.environ.get("LOG_LEVEL", "WARNING").upper()


def get_logger(name: str) -> logging.Logger:
    """Lambda 런타임이 설치한 root 핸들러를 재사용한다(핸들러 추가 금지 — 중복 줄 = 수집량 2배). 레벨만 환경변수로 제어."""
    logger = logging.getLogger(name)
    logger.setLevel(_LEVEL)
    return logger
