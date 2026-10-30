"""Flag heredocs inside command/process substitutions whose body bash 3.2 cannot parse.

Usage: heredoc-scan.py FILE...   (exit 1 and print file:line: reason on a finding)
"""
import re
import sys

OPEN_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SUBST_RE = re.compile(r"(?<!\$\()\$\((?!\()|<\(|>\(")


def scan(path):
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except (UnicodeDecodeError, OSError):
        return []
    found = []
    i = depth = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("#"):
            i += 1
            continue
        m = OPEN_RE.search(line)
        code = re.sub(r"'[^']*'|\"[^\"]*\"", "", line[: m.start()] if m else line)
        depth = max(depth + len(SUBST_RE.findall(code)) - code.count(")"), 0)
        if m:
            tag, j, body = m.group(2), i + 1, []
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j])
                j += 1
            if depth > 0 or re.search(r"\$\(|<\(", line[: m.start()]):
                text = "\n".join(body)
                why = []
                if text.count("'") % 2:
                    why.append("odd single quotes")
                if text.count('"') % 2:
                    why.append("odd double quotes")
                if "`" in text:
                    why.append("backtick")
                if text.count("(") != text.count(")"):
                    why.append("unbalanced parentheses")
                if why:
                    found.append("%s:%d: %s" % (path, i + 1, ", ".join(why)))
            i = j
        i += 1
    return found


if __name__ == "__main__":
    findings = [f for p in sys.argv[1:] for f in scan(p)]
    if findings:
        print("\n".join(findings))
        sys.exit(1)
