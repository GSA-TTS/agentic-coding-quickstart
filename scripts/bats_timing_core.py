"""Parsing and sanitizing half of summarize-bats-timing (Python 3 stdlib only).

Turns a bats TAP stream into `Stats`. Every test name is untrusted text; `clean`
and `md` are the only routes from the log to Markdown or JSON.

Result-line formats the pinned bats-core emits with --timing (ADR-0025):

  ok 1 name in 123ms                      raw stream: the `cat` formatter, i.e. any
  not ok 2 name in 4ms # timeout after 5s plain `bats --timing` run, `--jobs`, and
  ok 3 name in 6ms # skip reason          the xargs fallback in test-acq-bats
  ok 1 name # in 123 ms                   bats-format-tap: used when a report
  not ok 2 name # in 4 ms # timeout after 5 s   formatter is requested
  ok 3 name # skip reason                 skipped tests carry no timing here

The duration and timeout markers are matched only at the end of the line, so a
test name that merely contains "in 5ms" is not mistaken for a duration.
"""

import calendar
import heapq
import os
import re
import time
import unicodedata

TOP_TESTS = 15
TOP_FILES = 10
MAX_FAILED_SHOWN = 20
JSON_MAX_TESTS = 200
MAX_LINE = 4096
MAX_NAME = 160
UNMAPPED = "(unmapped)"
AMBIGUOUS = "(ambiguous name)"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STAMP_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z ")
RESULT_RE = re.compile(
    r"^(?P<not>not )?ok (?P<num>\d+) (?P<name>.*?)"
    r"(?: (?:# in (?P<fmt_ms>\d{1,9}) ms|in (?P<raw_ms>\d{1,9})ms))?"
    r"(?: # timeout after \d{1,9} ?s)?"
    r"(?P<skip> # (?:skip|SKIP|todo|TODO)\b.*)?$"
)
SKIP_RE = re.compile(r" # (?:skip|SKIP)\b")
PLAN_RE = re.compile(r"^1\.\.(\d+)$")
WORKERS_RE = re.compile(r"test-acq-bats: workers=(\d+)\b")
TEST_DECL_RE = re.compile(r"^\s*@test\s+(.*[^\s])\s+\{")
SHARD_RE = re.compile(r"[^A-Za-z0-9._-]")



class Note(Exception):
    """A user-facing, fixed-text problem (never carries untrusted text)."""



def parse_stamp(line):
    m = STAMP_RE.match(line)
    if not m:
        return None
    try:
        return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + (
            float(m.group(2)) if m.group(2) else 0.0
        )
    except (ValueError, OverflowError):
        return None


def clean(text, limit=MAX_NAME):
    out = []
    for ch in text:
        # Control, format (bidi/zero-width), line/paragraph separators, surrogates.
        bad = unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")
        out.append(" " if bad else ch)
    s = "".join(out).strip()
    return s if len(s) <= limit else s[: limit - 1] + "\u2026"


_MD_ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;", "|": "&#124;"}
_MD_BACKSLASH = set("\\`*_[]~")
_ZWSP = "\u200b"  # breaks GFM autolinks/mentions/math; inserted after these
_MD_BREAK_AFTER = set("@#$")


def md(text, limit=MAX_NAME):
    out = []
    for ch in clean(text, limit):
        if ch in _MD_ESC:
            out.append(_MD_ESC[ch])
        elif ch in _MD_BACKSLASH:
            out.append("\\" + ch)
        elif ch in _MD_BREAK_AFTER:
            out.append(ch + _ZWSP)
        else:
            out.append(ch)
    return "".join(out).replace("://", ":" + _ZWSP + "//").replace("www.", "www" + _ZWSP + ".")


def unquote_test_name(expr):
    if len(expr) >= 2 and expr[0] == expr[-1] == '"':
        return re.sub(r'\\(["\\$`])', r"\1", expr[1:-1])
    if len(expr) >= 2 and expr[0] == expr[-1] == "'":
        return expr[1:-1]
    return expr


def load_name_map(tests_dir):
    """Map test name -> sorted list of .bats basenames declaring it."""
    names = {}
    try:
        entries = sorted(os.listdir(tests_dir))
    except OSError:
        return names
    for entry in entries:
        if not entry.endswith(".bats"):
            continue
        try:
            with open(os.path.join(tests_dir, entry), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = TEST_DECL_RE.match(line)
                    if m:
                        files = names.setdefault(unquote_test_name(m.group(1)), [])
                        if entry not in files:
                            files.append(entry)
        except OSError:
            continue
    return names

class Stats:
    def __init__(self, name_map):
        self.name_map = name_map
        self.passed = self.failed = self.skipped = self.untimed = 0
        self.planned = 0
        self.sum_ms = 0
        self.workers = None
        self.slow = []  # min-heap of (ms, -seq, name, file, status)
        self.files = {}  # file -> [tests, ms, max_ms]
        self.failed_names = []
        self.seq = 0
        self.first_stamp = self.last_stamp = self.workers_stamp = None

    def file_for(self, name):
        cands = self.name_map.get(name)
        if not cands:
            return UNMAPPED
        return cands[0] if len(cands) == 1 else AMBIGUOUS

    def add_result(self, failed, name, ms, skipped):
        file = self.file_for(name)
        if skipped:
            self.skipped += 1
        elif failed:
            self.failed += 1
            if len(self.failed_names) < MAX_FAILED_SHOWN:
                self.failed_names.append((name, file))
        else:
            self.passed += 1
        entry = self.files.setdefault(file, [0, 0, 0])
        entry[0] += 1
        if ms is None:
            self.untimed += 1
            return
        if skipped:
            return
        self.sum_ms += ms
        entry[1] += ms
        entry[2] = max(entry[2], ms)
        self.seq += 1
        item = (ms, -self.seq, name, file, "not ok" if failed else "ok")
        if len(self.slow) < JSON_MAX_TESTS:
            heapq.heappush(self.slow, item)
        elif item > self.slow[0]:
            heapq.heapreplace(self.slow, item)

    @property
    def total(self):
        return self.passed + self.failed + self.skipped

    @property
    def timed(self):
        return self.total - self.untimed


def consume(stream, stats):
    while True:
        raw = stream.readline(MAX_LINE)
        if not raw:
            break
        while len(raw) == MAX_LINE and not raw.endswith("\n"):
            chunk = stream.readline(MAX_LINE)  # drop the rest of an over-long line
            if not chunk or chunk.endswith("\n"):
                break
        consume_line(ANSI_RE.sub("", raw).rstrip("\r\n"), stats)


def consume_line(line, stats):
    stamp = parse_stamp(line)
    body = STAMP_RE.sub("", line, count=1) if stamp is not None else line
    m = WORKERS_RE.search(body)
    if m and stats.workers is None:
        stats.workers = int(m.group(1))
        stats.workers_stamp = stamp
    m = PLAN_RE.match(body)
    if m:
        stats.planned += int(m.group(1))
        if stamp is not None and stats.first_stamp is None:
            stats.first_stamp = stamp
        return
    m = RESULT_RE.match(body)
    if not m:
        return
    ms = m.group("fmt_ms") if m.group("fmt_ms") is not None else m.group("raw_ms")
    stats.add_result(
        bool(m.group("not")),
        m.group("name"),
        None if ms is None else int(ms),
        bool(m.group("skip") and SKIP_RE.match(m.group("skip"))),
    )
    if stamp is not None:
        if stats.first_stamp is None:
            stats.first_stamp = stamp
        stats.last_stamp = stamp
