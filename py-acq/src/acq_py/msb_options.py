"""Create-time msb environment controls, matching the Bash adapter."""

from __future__ import annotations

import ntpath
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

from . import hostexec, state, userdirs


def sizing(memory: str | None, cpus: str | None) -> list[str]:
    """Preserve Bash's character-class checks, including empty-value omission."""
    flags: list[str] = []
    for var, value, pattern, hint, flag in (
        ("ACQ_MSB_MEMORY", memory, r"[0-9GMgm.]+", "e.g. 4G, 4096, 512M", "-m"),
        ("ACQ_MSB_CPUS", cpus, r"[0-9]+", "a positive integer", "-c"),
    ):
        if not value:
            continue
        if not re.fullmatch(pattern, value) or (var == "ACQ_MSB_CPUS" and value == "0"):
            print(f"acq(msb): warning: ignoring invalid {var}='{value}' (expected {hint}).", file=sys.stderr)
        else:
            flags += [flag, value]
    return flags


def pull_flags() -> list[str]:
    value = os.environ.get("ACQ_MSB_PULL", "")
    if value in ("always", "if-missing", "never"):
        return ["--pull", value]
    if value:
        print(f"acq(msb): ignoring invalid ACQ_MSB_PULL='{value}' "
              "(expected: always | if-missing | never)", file=sys.stderr)
    return []


def host_resolver_lines() -> str:
    """Read the same global resolver list msb uses on the host."""
    try:
        return Path("/etc/resolv.conf").read_text()
    except OSError:
        return ""


def host_resolvers_in_cgnat() -> bool:
    for line in host_resolver_lines().splitlines():
        words = line.split()
        if len(words) < 2 or words[0] != "nameserver":
            continue
        match = re.fullmatch(r"100\.([0-9]+)\..*\..*", words[1])
        if match and 64 <= int(match[1]) <= 127:
            return True
    return False


def dns_flags() -> list[str]:
    flags: list[str] = []
    nameserver = os.environ.get("ACQ_MSB_DNS_NAMESERVER", "")
    if nameserver:
        flags += ["--dns-nameserver", nameserver]
    raw = os.environ.get("ACQ_MSB_DNS_REBIND_PROTECTION", "")
    value = raw.lower()
    if value not in ("", "1", "true", "yes", "on", "0", "false", "no", "off"):
        print(f"acq(msb): WARNING: invalid ACQ_MSB_DNS_REBIND_PROTECTION={raw} "
              "(expected 1|0|empty); using auto", file=sys.stderr)
        value = ""
    if value in ("1", "true", "yes", "on"):
        return flags
    if value in ("0", "false", "no", "off"):
        return [*flags, "--no-dns-rebind-protection"]
    if host_resolvers_in_cgnat():
        print("acq(msb): host resolvers are in 100.64/10 (ZPA); disabling guest DNS rebind "
              "protection so split-horizon names resolve", file=sys.stderr)
        flags.append("--no-dns-rebind-protection")
    return flags


def _safe_path(path: Path) -> bool:
    """Reject symlinks except for macOS's standard root directory aliases."""
    try:
        if sys.platform == "darwin" and len(path.parts) > 1 and path.parts[1] in ("var", "tmp", "etc"):
            root = Path(path.anchor) / path.parts[1]
            canonical = Path("/private") / path.parts[1]
            # Only trust the OS alias to its standard destination. All remaining
            # components, including the destination's ancestors, are checked.
            if root.resolve() == canonical:
                path = canonical.joinpath(*path.parts[2:])
        return not any(p.is_symlink() or p.is_junction() for p in (path, *path.parents))
    except OSError:
        return False


def _readable_pem(path: Path) -> bool:
    try:
        info = path.lstat()
        return (_safe_path(path) and stat.S_ISREG(info.st_mode)
                and info.st_size > 0 and os.access(path, os.R_OK))
    except OSError:
        return False


def ca_host_path(value: str) -> str:
    """Translate the CA list's POSIX vocabulary for the native Windows CLI."""
    if sys.platform != "win32":
        return value
    if value.startswith("/unc/"):
        return "//" + value[5:]
    if re.match(r"^/[A-Za-z]/", value):
        return value[1].upper() + ":" + value[2:]
    # Rooted paths without a drive are not host-absolute on Windows.
    return value


def upstream_ca_flags() -> list[str]:
    """Explicit readable PEMs win; otherwise try the macOS search-list export."""
    if os.environ.get("ACQ_MSB_NO_UPSTREAM_CA"):
        return []
    flags: list[str] = []
    for value in re.split(r"[:\s]+", os.environ.get("ACQ_MSB_UPSTREAM_CA_CERT", "")):
        if not value:
            continue
        host = ca_host_path(value)
        absolute = ntpath.isabs(host) and bool(ntpath.splitdrive(host)[0]) if sys.platform == "win32" else userdirs.is_absolute(host)
        if not absolute:
            print("acq(msb): warning: ACQ_MSB_UPSTREAM_CA_CERT path is not absolute, "
                  f"skipping: {value}", file=sys.stderr)
        elif _readable_pem(Path(host)):
            flags += ["--tls-upstream-ca-cert", host]
        else:
            print("acq(msb): warning: ACQ_MSB_UPSTREAM_CA_CERT path not readable, "
                  f"skipping: {value}", file=sys.stderr)
    if flags:
        return flags
    auto = os.environ.get("ACQ_MSB_UPSTREAM_CA_AUTODETECT", "1").lower()
    if auto in ("", "0", "false", "no", "off") or sys.platform != "darwin":
        return []
    security = hostexec.which("security")
    if not security:
        return []
    try:
        out = userdirs.path_override("ACQ_MSB_UPSTREAM_CA_FILE") or state.state_dir() / "msb/host-upstream-cas.pem"
    except userdirs.UserDirError:
        return []
    return _export_host_cas(security, out)


def _export_host_cas(security: str, out: Path) -> list[str]:
    """Publish only a successful certificate export, using a private temporary file."""
    if not _safe_path(out) or (out.exists() and not out.is_file()):
        return []
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        print(f"acq(msb): warning: cannot create upstream-CA dir {out.parent}; skipping auto-detect", file=sys.stderr)
        return []
    try:
        fd, name = tempfile.mkstemp(prefix=out.name + ".", dir=out.parent)
    except OSError:
        print("acq(msb): warning: cannot create temp file for upstream-CA bundle; skipping auto-detect", file=sys.stderr)
        return []
    temp = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            proc = hostexec.run_captured([security, "find-certificate", "-a", "-p"])
            if proc.returncode or "BEGIN CERTIFICATE" not in proc.stdout:
                _export_note()
                return []
            stream.write(proc.stdout)
        temp.chmod(0o644)
        if not _safe_path(out):
            return []
        temp.replace(out)
        return ["--tls-upstream-ca-cert", str(out)]
    except OSError:
        return []
    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def _export_note() -> None:
    print("acq(msb): note: could not export host CAs for the TLS-intercept upstream verifier;\n"
          "acq(msb):   msb will fall back to its own native-cert loading. If egress fails with\n"
          "acq(msb):   a TLS 'unexpected eof' behind a corporate proxy that terminates the\n"
          "acq(msb):   endpoint, set ACQ_MSB_UPSTREAM_CA_CERT to your proxy's root CA PEM.\n"
          "acq(msb):   See docs/KNOWN_FAILURE_MODES.md §30.", file=sys.stderr)
