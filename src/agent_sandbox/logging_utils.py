from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from pathlib import Path


def get_logger(log_file: Path) -> logging.Logger:
    logger = logging.getLogger("agent_sandbox")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    log_file.parent.mkdir(parents=True, exist_ok=True)
    handler = logging.FileHandler(log_file, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    logger.propagate = False
    return logger


def audit_event(logger: logging.Logger, event: str, **fields: object) -> None:
    payload = {"timestamp": datetime.now(UTC).isoformat(), "event": event, **fields}
    logger.info(json.dumps(payload, sort_keys=True))
