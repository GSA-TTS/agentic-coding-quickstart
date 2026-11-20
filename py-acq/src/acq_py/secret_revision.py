"""Non-secret store identity and write epochs (ADR-0053).

Callers hold the secret-store lock. This module never accepts a credential value.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from pathlib import Path

from . import state

_KEY = re.compile(r"acq\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?")
_TOKEN = re.compile(r"[ar]:[0-9a-f]{32}")


def token(prefix: str) -> str:
    return prefix + ":" + secrets.token_hex(16)


def path_for(key: str) -> Path:
    if not _KEY.fullmatch(key):
        raise state.StateSchemaError("invalid credential revision key")
    return state.state_dir() / "secret-rev" / f"{key}.json"


def private_directory(directory: Path) -> None:
    missing = []
    while not directory.exists():
        missing.append(directory)
        directory = directory.parent
    for path in reversed(missing):
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass


def write(path: Path, document: dict) -> None:
    private_directory(path.parent)
    state.atomic_write_text(path, json.dumps(document, sort_keys=True) + "\n")
    if os.name == "nt":
        return
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read(path: Path) -> dict | None:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        raise state.StateSchemaError("cannot read credential authority or revision record") from None
    try:
        doc = json.loads(text)
    except ValueError:
        raise state.StateSchemaError("invalid credential authority or revision record") from None
    if not isinstance(doc, dict):
        raise state.StateSchemaError("invalid credential authority or revision record")
    return doc


def authority_ok(doc: object) -> bool:
    return doc is None or (
        isinstance(doc, dict) and set(doc) == {"kind", "id", "location"}
        and doc["kind"] in ("file", "dpapi", "metadata", "provider-pin")
        and isinstance(doc["id"], str) and re.fullmatch(r"a:[0-9a-f]{32}", doc["id"]) is not None
        and isinstance(doc["location"], str) and re.fullmatch(r"[0-9a-f]{64}", doc["location"]) is not None
    )


def authority(directory: Path, kind: str, *, establish: bool = False) -> dict | None:
    """Read the actual location's marker; only explicit writers establish one."""
    location = hashlib.sha256(os.path.normcase(os.path.realpath(directory)).encode("utf-8")).hexdigest()
    path = directory / f".acq-authority-{kind}.json"
    marker = _read(path)
    if marker is not None:
        if set(marker) != {"schema", "authority"} or type(marker["schema"]) is not int or marker["schema"] != 1:
            raise state.StateSchemaError("invalid credential authority marker")
        found = marker["authority"]
        if found is None or not authority_ok(found):
            raise state.StateSchemaError("invalid credential authority marker")
        if found["kind"] == kind and found["location"] == location:
            return found
    if not establish:
        return None
    found = {"kind": kind, "id": token("a"), "location": location}
    write(path, {"schema": 1, "authority": found})
    return found


def read(key: str) -> dict:
    """Missing and pre-authority records are unknown; malformed records refuse."""
    doc = _read(path_for(key))
    unknown = {"schema": 1, "committed": None, "pending": None, "authority": {"value": None, "metadata": None}}
    if doc is None:
        return unknown
    if set(doc) == {"committed", "pending"}:
        for item in doc.values():
            if item is not None and (not isinstance(item, str) or re.fullmatch(r"r:[0-9a-f]{32}", item) is None):
                raise state.StateSchemaError("invalid legacy credential revision record")
        return {**unknown, "pending": doc["pending"]}
    if set(doc) != set(unknown) or type(doc["schema"]) is not int or doc["schema"] != 1:
        raise state.StateSchemaError("unsupported credential revision schema")
    for field in ("committed", "pending"):
        item = doc[field]
        if item is not None and (not isinstance(item, str) or re.fullmatch(r"r:[0-9a-f]{32}", item) is None):
            raise state.StateSchemaError("invalid credential revision token")
    auth = doc["authority"]
    if not isinstance(auth, dict) or set(auth) != {"value", "metadata"} or not all(authority_ok(a) for a in auth.values()):
        raise state.StateSchemaError("invalid credential revision authority")
    return doc
