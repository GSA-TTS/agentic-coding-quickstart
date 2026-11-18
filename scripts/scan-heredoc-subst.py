#!/usr/bin/env python3
"""Flag here-documents inside command/process substitutions that bash 3.2 mis-parses.

bash 3.2 scans the body of a here-document that sits inside $( ) or <( ) for
quote and parenthesis balance, even though the body is plain text. A body with an
odd number of ' or " characters, an unpaired backtick, or unbalanced parentheses
fails at PARSE time ("unexpected EOF while looking for matching ...", "bad
substitution: no closing ')'"). bash 4+ accepts the same text, so only a bash 3.2
run notices. The authoritative check is `bash-3.2 -n FILE`; this scan gives the
same warning under any bash, for developers without a 3.2 interpreter.

It is a best-effort line-based heuristic, NOT a shell parser: substitution depth is
tracked by counting `$(`, `<(`, `>(` against `)` outside quoted strings, ignoring
arithmetic, `case` pattern heads and function heads. It can miss exotic layouts
and can report a false positive (comments and multi-line quotes are not modeled). The authority is the real parser:
`scripts/test-acq-bash32 --syntax FILE` (bash 3.2 -n).

Usage: scan-heredoc-subst.py FILE...   (prints file:line: reason; exit 1 on findings)
"""
import os
import re
import sys

# `<<` or `<<-` then a delimiter (optionally quoted or backslash-escaped); not `<<<`.
OPEN_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)\\?([A-Za-z_][A-Za-z0-9_]*)\1")
SUBST_RE = re.compile(r"(?<!\$\()\$\((?!\()|<\(|>\(")
QUOTED_RE = re.compile(r"'[^']*'|\"(?:[^\"\\$]|\\.|\$(?!\())*\"")
ARITH_RE = re.compile(r"\$\(\(.*?\)\)|(?<![$<>])\(\([^()]*\)\)")
CASE_HEAD_RE = re.compile(r"^\s*\(?[^()\s$`'\"]+(\|[^()\s$`'\"]+)*\)")
FUNC_HEAD_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_:.-]*\s*\(\)")


def hazards(body):
    why = []
    if body.count("'") % 2:
        why.append("odd single quotes")
    if body.count('"') % 2:
        why.append("odd double quotes")
    if body.count("`") % 2:
        why.append("unpaired backtick")
    if body.count("(") != body.count(")"):
        why.append("unbalanced parentheses")
    return why


def mask(line):
    """Blank quoted strings and a trailing comment, preserving the line length."""
    out = QUOTED_RE.sub(lambda m: m.group(0)[0] + "x" * (len(m.group(0)) - 2) + m.group(0)[0], line)
    # Blank the comment with spaces so offsets stay aligned with the original line.
    return re.sub(r"(^|\s)#.*$", lambda m: m.group(1) + " " * (len(m.group(0)) - len(m.group(1))), out)


def paren_delta(masked):
    code = ARITH_RE.sub("", masked)
    code = FUNC_HEAD_RE.sub("", code)
    code = CASE_HEAD_RE.sub("", code, count=1)
    code = QUOTED_RE.sub("", code)
    return len(SUBST_RE.findall(code)) - code.count(")"), bool(SUBST_RE.search(code))


def scan(path):
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
    except (UnicodeDecodeError, OSError) as err:
        return ["%s:0: unreadable (%s)" % (path, err)]
    found = []
    i = depth = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("#"):
            i += 1
            continue
        masked = mask(line)
        openers = [m for m in OPEN_RE.finditer(line) if masked[m.start()] == "<"]
        head = masked[: openers[0].start()] if openers else masked
        delta = paren_delta(head)[0]
        in_subst = depth + delta > 0
        depth = max(depth + paren_delta(masked)[0], 0)
        resume = i
        for m in openers:
            tag, j, body = m.group(2), resume + 1, []
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                found.append("%s:%d: unterminated here-document '%s'" % (path, i + 1, tag))
                break
            if in_subst:
                why = hazards("\n".join(body))
                if why:
                    found.append("%s:%d: %s" % (path, i + 1, ", ".join(why)))
            resume = j
        i = resume + 1
    return found


def main(paths):
    findings = []
    for path in paths:
        try:
            findings.extend(scan(path))
        except Exception as err:  # noqa: BLE001 - never leak a traceback; fail closed
            print("scan-heredoc-subst: internal error scanning %s: %s: %s" % (path, type(err).__name__, err))
            return 2
    if findings:
        try:
            print("\n".join(findings))
            sys.stdout.flush()
        except BrokenPipeError:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
