from __future__ import annotations

import json
import logging
from pathlib import Path

from agent_sandbox.logging_utils import audit_event, get_logger


def reset_agent_sandbox_logger() -> None:
    logger = logging.getLogger("agent_sandbox")
    for handler in list(logger.handlers):
        handler.flush()
        handler.close()
        logger.removeHandler(handler)


def test_get_logger_creates_log_file_parent(tmp_path: Path) -> None:
    reset_agent_sandbox_logger()
    log_file = tmp_path / ".agent-sandbox" / "logs" / "agent-sandbox.log"
    logger = get_logger(log_file)

    assert logger.name == "agent_sandbox"
    assert log_file.parent.exists()


def test_get_logger_reuses_existing_logger_handlers(tmp_path: Path) -> None:
    reset_agent_sandbox_logger()
    log_file = tmp_path / "logs" / "agent-sandbox.log"
    logger_one = get_logger(log_file)
    handler_count = len(logger_one.handlers)

    logger_two = get_logger(log_file)

    assert logger_two is logger_one
    assert len(logger_two.handlers) == handler_count


def test_audit_event_writes_json_line(tmp_path: Path) -> None:
    reset_agent_sandbox_logger()
    log_file = tmp_path / "logs" / "agent-sandbox.log"
    logger = get_logger(log_file)

    repo_marker = str(tmp_path / "demo-repo")
    audit_event(logger, "test_event", repo_root=repo_marker, ok=True)

    for handler in logger.handlers:
        handler.flush()

    lines = log_file.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1

    payload = json.loads(lines[0])
    assert payload["event"] == "test_event"
    assert payload["repo_root"] == repo_marker
    assert payload["ok"] is True
    assert "timestamp" in payload
