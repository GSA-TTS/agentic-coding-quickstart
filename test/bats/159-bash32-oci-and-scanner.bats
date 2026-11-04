#!/usr/bin/env bats
# scripts/fetch-bash32-oci.py launcher generation (shell-injection safety) and
# scripts/scan-heredoc-subst.py robustness (no traceback on odd input). Split from
# 152-bash32-runner.bats, which covers the scripts/test-acq-bash32 runner itself.

load 'helper'

setup() {
  acq_setup_stubs
  RUNNER="$REPO_ROOT/scripts/test-acq-bash32"
}

teardown() { acq_teardown_stubs; }

# --- fetch-bash32-oci.py launcher generation -------------------------------------

FETCH_OCI_PY() { printf '%s' "$REPO_ROOT/scripts/fetch-bash32-oci.py"; }

# Generate the launcher for a hostile prefix, put a fake musl loader (that records its
# argv NUL-separated) at the quoted location, run the launcher, and require that the
# loader saw exactly the literal paths and that no injected command ran.
@test "fetch-oci launcher: hostile prefixes run as literal text, never as shell syntax" {
  run python3 - "$(FETCH_OCI_PY)" "$STUBDIR" <<'PY'
import importlib.util, os, subprocess, sys

spec = importlib.util.spec_from_file_location("fetch_oci", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = sys.argv[2]
arch = "x86_64"
hostile = ["it's", "sp ace", "$(touch CANARY)", "`touch CANARY`", "semi;touch CANARY",
           "new\nline;touch CANARY", "-dash", "dq\"touch CANARY", "back\\slash", "a'$(touch CANARY)'b",
           "amp&&touch CANARY", "glob*?[x]", "~tilde", "pipe|touch CANARY"]
bad = 0
for i, name in enumerate(hostile):
    prefix = os.path.join(root, "p%d" % i, name)
    os.makedirs(os.path.join(prefix, "bin"))
    os.makedirs(os.path.join(prefix, "lib"))
    out = os.path.join(root, "argv%d" % i)
    loader = os.path.join(prefix, "lib", "ld-musl-%s.so.1" % arch)
    with open(loader, "w") as f:
        f.write("#!/bin/sh\nfor a in \"$@\"; do printf '%%s\\0' \"$a\"; done > '%s'\n" % out)
    os.chmod(loader, 0o755)
    launcher = os.path.join(prefix, "bin", "bash")
    with open(launcher, "w") as f:
        f.write(mod.launcher_text(prefix, arch))
    os.chmod(launcher, 0o755)
    cwd = os.path.join(root, "cwd%d" % i)
    os.makedirs(cwd)
    r = subprocess.run([launcher, "ARG ONE", "$(touch CANARY)"], cwd=cwd, capture_output=True, text=True)
    want = ["--library-path", prefix + "/lib", prefix + "/libexec/bash", "ARG ONE", "$(touch CANARY)"]
    got = open(out, "rb").read().decode().split("\0")[:-1] if os.path.exists(out) else None
    canary = [p for p in (os.path.join(cwd, "CANARY"), os.path.join(root, "CANARY"), os.path.join(prefix, "CANARY"),
                          os.path.join(os.path.dirname(prefix), "CANARY")) if os.path.exists(p)]
    if r.returncode != 0 or got != want or canary:
        bad += 1
        print("FAIL %r rc=%s stderr=%r got=%r canary=%r" % (name, r.returncode, r.stderr, got, canary))
print("hostile-ok" if not bad else "hostile-bad")
sys.exit(1 if bad else 0)
PY
  assert_success
  assert_output "hostile-ok"
}

@test "fetch-oci launcher: control characters in the prefix fail closed before any network or disk work" {
  local pfx
  pfx="$(printf '%s/nl\nprefix' "$STUBDIR")"
  run python3 -B "$(FETCH_OCI_PY)" "$pfx"
  assert_failure
  assert_output --partial "must not contain control characters"
  run bash -c 'ls -A "$1" | grep -c "^nl"' _ "$STUBDIR"
  assert_output "0"
  run python3 -B "$(FETCH_OCI_PY)" "$(printf '%s/tab\tprefix' "$STUBDIR")"
  assert_failure
  assert_output --partial "must not contain control characters"
  run python3 -B "$(FETCH_OCI_PY)" /
  assert_failure
  assert_output --partial "filesystem root"
}

@test "fetch-oci launcher: a relative prefix (including a leading-dash one) is refused, not treated as an option or path" {
  run python3 -B "$(FETCH_OCI_PY)" "-rf"
  assert_failure
  assert_output --partial "absolute path"
  run python3 -B "$(FETCH_OCI_PY)" "rel/prefix"
  assert_failure
  assert_output --partial "absolute path"
  [ ! -e "$BATS_TEST_DIRNAME/../../rel" ] && [ ! -e rel ]
}

# --- scan-heredoc-subst.py robustness --------------------------------------------

@test "bash32 --lint: heredoc, substitution and process-substitution text in comments or strings does not crash" {
  printf '%s\n' \
    'x=$(cat) # example: cat <<EOF' \
    'y=1 # uses $( and <( and >( in prose' \
    'echo "<<EOF" "$(date)" # trailing <<TAG' \
    "echo '<<EOF' # it's fine" \
    'z=$(printf %s "a<<b") # <<X' \
    'cat <<EOF # note: <<NESTED' \
    'body' \
    'EOF' > "$STUBDIR/comments.sh"
  run "$RUNNER" --lint "$STUBDIR/comments.sh"
  assert_success
  refute_output --partial "Traceback"
  refute_output --partial "IndexError"
}

@test "bash32 --lint: a real finding is still reported when the line also has a trailing heredoc-looking comment" {
  printf '%s\n' 'y=$(cat <<E # also <<EOF' "it's" 'E' ')' > "$STUBDIR/mixed.sh"
  run "$RUNNER" --lint "$STUBDIR/mixed.sh"
  assert_failure 1
  assert_output --partial "mixed.sh:1: odd single quotes"
  refute_output --partial "Traceback"
}

@test "bash32 --lint: every truncation of every host-side shell file scans without a traceback" {
  run python3 - "$REPO_ROOT" "$STUBDIR" <<'PY'
import glob, importlib.util, os, random, sys
spec = importlib.util.spec_from_file_location("scan", os.path.join(sys.argv[1], "scripts", "scan-heredoc-subst.py"))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
root, tmp = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(root + "/*.sh") + glob.glob(root + "/scripts/*.sh") + glob.glob(root + "/acq.backends/*.sh")
               + [root + "/acq"])
rng = random.Random(632)
target = os.path.join(tmp, "fuzz.sh")
count = 0
for path in files:
    scan.scan(path)
    lines = open(path, encoding="utf-8").read().split("\n")
    for _ in range(60):
        sample = []
        for line in rng.sample(lines, min(len(lines), 12)):
            sample.append(line[: rng.randint(0, len(line))])
        with open(target, "w") as handle:
            handle.write("\n".join(sample))
        scan.scan(target)
        count += 1
print("scanned %d files, %d random truncations" % (len(files), count))
PY
  assert_success
  assert_output --partial "random truncations"
}

@test "bash32 --lint: an unexpected scanner exception is one clear error line, exit 2, no traceback" {
  run python3 - "$REPO_ROOT/scripts/scan-heredoc-subst.py" <<'PY'
import importlib.util, io, contextlib, sys
spec = importlib.util.spec_from_file_location("scan", sys.argv[1])
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
def boom(path):
    raise IndexError("string index out of range")
scan.scan = boom
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = scan.main(["x.sh"])
out = buf.getvalue()
assert rc == 2, rc
assert out.count("\n") == 1 and "internal error" in out and "Traceback" not in out, out
print("one-line-error")
PY
  assert_success
  assert_output "one-line-error"
}
