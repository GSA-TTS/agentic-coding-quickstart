"""Helpers for scripts/test-uninstall-macos (ADR-0048).

  run OUTPUT TIMEOUT [--no-tty] [--stderr FILE] [--reply EXPECT ANSWER]... -- CMD...
      Run CMD and capture its output in OUTPUT. By default CMD gets a
      pseudo-terminal (so `[ -t 0 ]` is true) and each --reply waits for EXPECT
      to appear in the terminal output after the previous match, then types
      ANSWER and Return. With --no-tty, stdin is /dev/null, stdout goes to
      OUTPUT and stderr to --stderr FILE (default: OUTPUT). Exit status is
      CMD's, except 124 (timed out) and 125 (a reply's prompt never appeared), so a prompt that was never
      shown cannot look like a pass. CMD runs in its own session/process group;
      the timeout covers the whole run including waiting for CMD to exit after
      its terminal closes, and on every exit path any process CMD left behind is
      sent SIGTERM and then SIGKILL, so nothing outlives the call. If the helper
      itself receives SIGTERM, SIGHUP or SIGINT it stops CMD's group the same way,
      appends "[uninstall-acceptance-helper interrupted by SIGxxx]" to OUTPUT, says so
      on stderr and exits 128+signal, so an interrupted run can never look like success.
  manifest PATH...
      Print one line per entry at or under each PATH (symlinks are never
      followed): absolute path, type, permission bits, size and a content digest or link
      target; a missing PATH prints "PATH MISSING". Timestamps are excluded so
      unchanged trees compare equal.
  make-shims DIR LOGFILE
      Write refusing stand-ins for privilege-escalation commands into DIR. Each
      one appends its name and arguments to LOGFILE and exits 1.
  trace-privilege FILE...
      Exit 1 and print the lines if a shell command trace (PS4 "+TRACE ") shows
      a privilege-escalation command in command position; otherwise exit 0.
  report --tsv FILE --json FILE --md FILE --not-exercised FILE [--require A,B,...] [--meta KEY=VALUE]...
      Turn the stage<TAB>status<TAB>detail results into results.json and a
      Markdown summary. The overall verdict is FAIL when any stage is FAIL or
      ABORTED, or when a stage named by --require is missing or not PASS;
      otherwise PASS. Exit status is 1 on FAIL. NOT-EXERCISED and BLOCKED are listed, never
      counted as passes.
"""
import hashlib
import json
import os
import re
import select
import signal
import stat
import subprocess
import sys
import time

try:
    import pty
except ImportError:  # pragma: no cover - only on non-POSIX hosts
    pty = None


def usage():
    sys.stderr.write(__doc__)
    sys.exit(2)


def parse_run(args):
    if len(args) < 3:
        usage()
    out, timeout, rest = args[0], float(args[1]), args[2:]
    opts = {"no_tty": False, "stderr": None, "replies": []}
    while rest and rest[0] != "--":
        if rest[0] == "--no-tty":
            opts["no_tty"] = True
            rest = rest[1:]
        elif rest[0] == "--stderr" and len(rest) >= 2:
            opts["stderr"] = rest[1]
            rest = rest[2:]
        elif rest[0] == "--reply" and len(rest) >= 3:
            opts["replies"].append((rest[1].encode(), rest[2].encode()))
            rest = rest[3:]
        else:
            usage()
    if len(rest) < 2 or (opts["no_tty"] and opts["replies"]):
        usage()
    return out, timeout, opts, rest[1:]


# A signal handler that raised could fire inside a cleanup block and abandon it, so the
# handler only records the first signal and every wait loop polls for it. Cleanup then
# always runs to completion; later signals are ignored.
INTERRUPT = {"signum": 0}
POLL = 0.2
INTERRUPT_MARK = "[uninstall-acceptance-helper interrupted by %s]"


def on_signal(signum, frame):
    if not INTERRUPT["signum"]:
        INTERRUPT["signum"] = signum


def interrupted():
    return INTERRUPT["signum"] != 0


def install_handlers():
    INTERRUPT["signum"] = 0
    for name in ("SIGTERM", "SIGHUP", "SIGINT"):
        signal.signal(getattr(signal, name), on_signal)


def pump(fd, sink, replies, deadline):
    buf, pos = b"", 0
    while True:
        if interrupted():
            return "interrupted"
        left = deadline - time.time()
        if left <= 0:
            return "timeout"
        ready, _, _ = select.select([fd], [], [], min(left, POLL))
        if fd not in ready:
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            return "eof"
        sink.write(data)
        sink.flush()
        buf += data
        if replies:
            expect, answer = replies[0]
            hit = buf.find(expect, pos)
            if hit >= 0:
                os.write(fd, answer + b"\n")
                pos = hit + len(expect)
                replies.pop(0)


TERM_GRACE = 0.3


def stop_group(pgid):
    """End every process still in group PGID: SIGTERM, a short grace, then SIGKILL.

    Returns at once when the group is already empty, so the normal case costs nothing.
    """
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return  # macOS reports EPERM for a group holding only zombies
    time.sleep(TERM_GRACE)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def reap(pid, deadline):
    """Wait for PID until DEADLINE. Returns its wait status, or None on timeout or interruption."""
    while True:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            return status
        if interrupted() or time.time() >= deadline:
            return None
        time.sleep(0.02)


def run_tty(out, timeout, replies, cmd):
    deadline = time.time() + timeout
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(cmd[0], cmd)
        finally:
            os._exit(127)
    status, reaped = None, False
    try:
        with open(out, "wb") as sink:
            outcome = pump(fd, sink, replies, deadline)
        if outcome == "eof":
            status = reap(pid, deadline)
            reaped = status is not None
            outcome = "exited" if reaped else ("interrupted" if interrupted() else "timeout")
    finally:
        os.close(fd)
        stop_group(pid)
        if not reaped:
            _, status = os.waitpid(pid, 0)
    if outcome == "interrupted":
        return 1
    if outcome == "timeout":
        return 124
    if replies:
        sys.stderr.write("prompt never appeared: %r\n" % replies[0][0])
        return 125
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


def run_pipe(out, err, timeout, cmd):
    deadline = time.time() + timeout
    rc = None
    with open(out, "wb") as sink:
        errsink = open(err, "wb") if err else sink
        proc = None
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=sink, stderr=errsink,
                                    start_new_session=True)
            while rc is None and not interrupted():
                left = deadline - time.time()
                if left <= 0:
                    rc = 124
                    break
                try:
                    rc = proc.wait(timeout=min(left, POLL))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if proc is not None:
                stop_group(proc.pid)
                proc.wait()
            if err:
                errsink.close()
    if rc is None:
        return 1
    return 128 - rc if rc < 0 else rc


def note_interruption(out):
    name = signal.Signals(INTERRUPT["signum"]).name
    message = INTERRUPT_MARK % name
    sys.stderr.write(message + "\n")
    try:
        with open(out, "ab") as sink:
            sink.write(("\n" + message + "\n").encode())
    except OSError as exc:
        sys.stderr.write("cannot record the interruption in %s: %s\n" % (out, exc))


def cmd_run(args):
    out, timeout, opts, cmd = parse_run(args)
    install_handlers()
    if opts["no_tty"]:
        rc = run_pipe(out, opts["stderr"], timeout, cmd)
    else:
        rc = run_tty(out, timeout, opts["replies"], cmd)
    if interrupted():
        note_interruption(out)
        return 128 + INTERRUPT["signum"]
    return rc


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def entry(path):
    info = os.lstat(path)
    rel = path
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        return "%s link %04o -> %s" % (rel, mode, os.readlink(path))
    if stat.S_ISDIR(info.st_mode):
        return "%s dir %04o" % (rel, mode)
    if stat.S_ISREG(info.st_mode):
        return "%s file %04o %d %s" % (rel, mode, info.st_size, digest(path))
    return "%s other %04o" % (rel, mode)


def manifest_lines(path):
    path = os.path.abspath(path)
    if not os.path.lexists(path):
        return ["%s MISSING" % path]
    lines = [entry(path)]
    if os.path.isdir(path) and not os.path.islink(path):
        for base, dirs, files in os.walk(path, followlinks=False):
            for name in dirs + files:
                lines.append(entry(os.path.join(base, name)))
    return lines


def cmd_manifest(args):
    if not args:
        usage()
    lines = []
    for path in args:
        lines.extend(manifest_lines(path))
    print("\n".join(sorted(lines)))
    return 0


PRIVILEGE_COMMANDS = ("sudo", "doas")
WRAPPERS = r"(?:(?:command|exec|env|nohup|time|xargs|builtin)(?: +-[^ ]+)* +|[A-Za-z_][A-Za-z0-9_]*=[^ ]* +)*"
TRACE_RE = re.compile(r"^\++(?:TRACE)? +" + WRAPPERS + r"(?:/[^ ]*/)?(?:%s)(?: |$)" % "|".join(PRIVILEGE_COMMANDS))


def cmd_make_shims(args):
    if len(args) != 2:
        usage()
    directory, log = args
    os.makedirs(directory, exist_ok=True)
    for name in PRIVILEGE_COMMANDS:
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nprintf \'%s\\n\' "$0 $*" >> ' + "'" + log + "'" + '\nexit 1\n')
        os.chmod(path, 0o755)
    return 0


def cmd_trace_privilege(args):
    if not args:
        usage()
    hits = []
    for path in args:
        with open(path, encoding="utf-8", errors="replace") as handle:
            hits += [line.rstrip("\n") for line in handle if TRACE_RE.match(line)]
    if hits:
        print("\n".join(hits))
        return 1
    return 0


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t", 2)
            while len(parts) < 3:
                parts.append("")
            rows.append({"stage": parts[0], "status": parts[1], "detail": parts[2]})
    return rows


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def parse_report(args):
    opts = {"meta": [], "require": []}
    names = {"--tsv": "tsv", "--json": "json", "--md": "md", "--not-exercised": "notex"}
    rest = list(args)
    while rest:
        if rest[0] in names and len(rest) >= 2:
            opts[names[rest[0]]] = rest[1]
            rest = rest[2:]
        elif rest[0] == "--require" and len(rest) >= 2:
            opts["require"] = [n for n in rest[1].split(",") if n]
            rest = rest[2:]
        elif rest[0] == "--meta" and len(rest) >= 2 and "=" in rest[1]:
            key, _, value = rest[1].partition("=")
            opts["meta"].append((key, value))
            rest = rest[2:]
        else:
            usage()
    if not all(k in opts for k in names.values()):
        usage()
    return opts


def cmd_report(args):
    opts = parse_report(args)
    rows = read_rows(opts["tsv"])
    with open(opts["notex"], encoding="utf-8") as handle:
        notex = [line.strip() for line in handle if line.strip()]
    bad = [r for r in rows if r["status"] in ("FAIL", "ABORTED")]
    status_of = {r["stage"]: r["status"] for r in rows}
    unmet = [n for n in opts["require"] if status_of.get(n) != "PASS"]
    verdict = "FAIL" if bad or unmet or not rows else "PASS"
    meta = dict(opts["meta"])
    with open(opts["json"], "w", encoding="utf-8") as handle:
        json.dump({"verdict": verdict, "meta": meta, "unmet_required": unmet, "stages": rows, "not_exercised": notex}, handle, indent=2)
        handle.write("\n")
    lines = ["## macOS uninstall acceptance: %s" % verdict, "", "| Item | Value |", "| --- | --- |"]
    lines += ["| %s | %s |" % (cell(k), cell(v)) for k, v in opts["meta"]]
    if unmet:
        lines += ["", "Required stages not passed: %s" % ", ".join(unmet)]
    lines += ["", "| Stage | Result | Detail |", "| --- | --- | --- |"]
    lines += ["| %s | %s | %s |" % (cell(r["stage"]), r["status"], cell(r["detail"])) for r in rows]
    lines += ["", "### Not exercised by this workflow", ""]
    lines += ["- %s" % item for item in notex]
    with open(opts["md"], "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return 1 if verdict == "FAIL" else 0


def main(argv):
    if len(argv) < 2:
        usage()
    handlers = {
        "run": cmd_run,
        "manifest": cmd_manifest,
        "report": cmd_report,
        "make-shims": cmd_make_shims,
        "trace-privilege": cmd_trace_privilege,
    }
    if argv[1] not in handlers:
        usage()
    return handlers[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
