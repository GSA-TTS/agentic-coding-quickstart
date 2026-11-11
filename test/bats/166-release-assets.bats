#!/usr/bin/env bats
# Exercise the real builders offline; supplier downloads belong only to CI.
load './helper.bash'

setup() {
  cd "$REPO_ROOT" || return 1
  export WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/tree" "$WORK/wheelhouse" "$WORK/dist" "$WORK/home"
  export HOME="$WORK/home" ACQ_BUILD_VERSION=8.7.6 ACQ_BUILD_REVISION=0123456789abcdef0123456789abcdef01234567
  unset ACQ_RUNTIME ACQ_VERSION ACQ_SOURCE_REVISION ACQ_IMPL ACQ_INSTALL_SOURCE ACQ_INSTALL_DIR ACQ_INSTALL_BIN_DIR
  python3 -I - "$WORK" <<'PY'
import hashlib
from pathlib import Path
import shlex
import sys
import tarfile
import zipfile
w = Path(sys.argv[1])
p = w / 'supplier/python'
(p / 'bin').mkdir(parents=True)
# A regular-file stub allows the extraction filter to reject external symlinks
# while still running the host interpreter for the installed-launcher test.
# python-build-standalone ships bin/python3 as a symlink to the versioned
# interpreter; keep that shape so staging and packing are exercised on a link.
(p / 'bin/python3.14').write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
(p / 'bin/python3.14').chmod(0o755)
(p / 'bin/python3').symlink_to('python3.14')
(p / 'LICENSE.cpython.txt').write_text('fake supplier license\n')
(p / 'NOTICE').write_text('fake supplier notice\n')
with tarfile.open(w / 'runtime.tar.gz', 'w:gz') as tf:
    tf.add(p, arcname='python')
with zipfile.ZipFile(w / 'runtime.zip', 'w') as zf:
    for name in ('python.exe', 'LICENSE.txt', 'python314.zip', 'python314._pth'):
        zf.writestr(name, 'fake embedded runtime\n')
wheel = w / 'wheelhouse/fake-1.0-py3-none-any.whl'
wheel.write_bytes(b'fake validator wheel\n')
(w / 'wheelhouse/SHA256SUMS').write_text(hashlib.sha256(wheel.read_bytes()).hexdigest() + '  ' + wheel.name + '\n')
PY
  POSIX_SHA=$(sha256sum "$WORK/runtime.tar.gz"); POSIX_SHA=${POSIX_SHA%% *}
  WINDOWS_SHA=$(sha256sum "$WORK/runtime.zip"); WINDOWS_SHA=${WINDOWS_SHA%% *}
}

_build_dist() {
  local platform
  for platform in linux-x86_64 linux-aarch64 macos-arm64 macos-x86_64 windows-x86_64; do
    if [ "$platform" = windows-x86_64 ]; then
      scripts/assemble-release "$platform" "$WORK/runtime.zip" "$WINDOWS_SHA" "$WORK/wheelhouse" "$WORK/dist"
    else
      scripts/assemble-release "$platform" "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/wheelhouse" "$WORK/dist"
    fi
  done
  cp install.sh install.ps1 "$WORK/dist/"
  scripts/gen-provenance "$WORK/dist"
  scripts/gen-install-assets "$WORK/dist"
}

@test "release assets: POSIX hash mismatch leaves the tree unchanged" {
  echo keep > "$WORK/tree/sentinel"
  run scripts/stage-posix-runtime "$WORK/runtime.tar.gz" "${POSIX_SHA//[0-9a-f]/0}" "$WORK/tree"
  assert_failure
  assert_output --partial 'SHA-256 mismatch'
  [ "$(ls -A "$WORK/tree")" = sentinel ]
  [ "$(cat "$WORK/tree/sentinel")" = keep ]
}

@test "release assets: existing source or runtime is refused unchanged" {
  local name
  for name in src runtime; do
    mkdir -p "$WORK/tree/py-acq/$name"
    echo keep > "$WORK/tree/py-acq/$name/sentinel"
    run scripts/stage-posix-runtime "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/tree"
    assert_failure
    assert_output --partial 'already exists'
    [ "$(cat "$WORK/tree/py-acq/$name/sentinel")" = keep ]
    [ "$(ls -A "$WORK/tree/py-acq")" = "$name" ]
    mv "$WORK/tree/py-acq/$name" "$WORK/$name-saved"
  done
}

@test "release assets: unexpected POSIX layout fails without modifying the tree" {
  python3 -I - "$WORK" <<'PY'
from pathlib import Path
import io
import tarfile
import sys
with tarfile.open(Path(sys.argv[1]) / 'bad.tar.gz', 'w:gz') as tf:
    entry = tarfile.TarInfo('../escaped')
    entry.size = 1
    tf.addfile(entry, io.BytesIO(b'x'))
PY
  local digest
  digest=$(sha256sum "$WORK/bad.tar.gz"); digest=${digest%% *}
  run scripts/stage-posix-runtime "$WORK/bad.tar.gz" "$digest" "$WORK/tree"
  assert_failure
  assert_output --partial 'unexpected runtime layout'
  [ -z "$(ls -A "$WORK/tree")" ]
  [ ! -e "$WORK/escaped" ]
}

@test "release assets: a runtime symlink escaping the archive fails closed" {
  python3 -I - "$WORK" <<'PY'
from pathlib import Path
import io
import tarfile
import sys
with tarfile.open(Path(sys.argv[1]) / 'link.tar.gz', 'w:gz') as tf:
    entry = tarfile.TarInfo('python/bin/python3')
    entry.type = tarfile.SYMTYPE
    entry.linkname = '../../../outside'
    tf.addfile(entry)
PY
  local digest
  digest=$(sha256sum "$WORK/link.tar.gz"); digest=${digest%% *}
  run scripts/stage-posix-runtime "$WORK/link.tar.gz" "$digest" "$WORK/tree"
  assert_failure
  [ -z "$(ls -A "$WORK/tree")" ]
}

@test "release assets: POSIX stage retains notices and copies source without caches" {
  run scripts/stage-posix-runtime "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/tree"
  assert_success
  [ -x "$WORK/tree/py-acq/runtime/bin/python3" ]
  [ -f "$WORK/tree/py-acq/runtime/LICENSE.cpython.txt" ]
  [ -f "$WORK/tree/py-acq/runtime/NOTICE" ]
  [ -f "$WORK/tree/py-acq/src/acq_py/__main__.py" ]
  [ -z "$(find "$WORK/tree/py-acq/src" -name __pycache__ -o -name '_stub_*.py')" ]
}

@test "release assets: all archive layouts, baked identity and full dist match the manifests" {
  _build_dist
  python3 -I - "$WORK/dist" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import tarfile
import zipfile
root = Path(sys.argv[1])
assets = json.loads(Path('installer/assets.json').read_text())
for platform, spec in assets['platforms'].items():
    path = root / spec['archive']
    if spec['format'] == 'zip':
        with zipfile.ZipFile(path) as zf:
            names = set(zf.namelist())
            baked = zf.read('py-acq/src/acq_py/_build_info.py').decode()
            assert zf.read('py-acq/runtime/python314._pth') == b'python314.zip\r\n.\r\n..\\src\r\n'
    else:
        with tarfile.open(path) as tf:
            names = set(tf.getnames())
            for launcher in spec['components']['launchers']:
                assert tf.getmember(launcher).mode & 0o111, (platform, launcher)
            assert tf.getmember('py-acq/runtime/bin/python3').issym(), platform
            baked = tf.extractfile('py-acq/src/acq_py/_build_info.py').read().decode()
            assert 'py-acq/runtime/NOTICE' in names
    comp = spec['components']
    for name in [*comp['launchers'], comp['runtime']['path'], comp['source']+'__init__.py',
                 comp['backends']+'common.sh', comp['wheelhouse']+'SHA256SUMS', 'LICENSE', 'README.md']:
        assert name in names, (platform, name)
    identity = {}
    exec(baked, identity)
    assert identity['ACQ_VERSION'] == '8.7.6'
    assert identity['SOURCE_REVISION'] == '0123456789abcdef0123456789abcdef01234567'
provenance = json.loads((root / 'provenance.json').read_text())
template = json.loads(Path('installer/provenance.json').read_text())
assert provenance.keys() == template.keys()
assert provenance['acq'] == {'acq_version': '8.7.6', 'source_revision': '0123456789abcdef0123456789abcdef01234567'}
assert provenance['runtimes'].keys() == assets['platforms'].keys()
for platform, spec in assets['platforms'].items():
    assert provenance['runtimes'][platform] == {'supplier': spec['components']['runtime']['supplier'], 'version': '3.14.10'}
lines = (root / 'SHA256SUMS').read_text().splitlines()
assert len(lines) == 8
for line in lines:
    digest, name = line.split('  ')
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
PY
}

@test "release assets: assembly refuses an existing archive" {
  scripts/assemble-release linux-x86_64 "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/wheelhouse" "$WORK/dist"
  local before
  before=$(sha256sum "$WORK/dist/acq-linux-x86_64.tar.gz")
  run scripts/assemble-release linux-x86_64 "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/wheelhouse" "$WORK/dist"
  assert_failure
  assert_output --partial 'already exists'
  [ "$(sha256sum "$WORK/dist/acq-linux-x86_64.tar.gz")" = "$before" ]
}

@test "release assets: default build identity comes from package and checkout" {
  unset ACQ_BUILD_VERSION ACQ_BUILD_REVISION
  scripts/assemble-release linux-x86_64 "$WORK/runtime.tar.gz" "$POSIX_SHA" "$WORK/wheelhouse" "$WORK/dist"
  scripts/gen-provenance "$WORK/dist"
  python3 -I - "$WORK" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tarfile
w = Path(sys.argv[1])
p = json.loads((w / 'dist/provenance.json').read_text())['acq']
assert p['acq_version'] == json.loads(Path('package.json').read_text())['version']
assert p['source_revision'] == subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
with tarfile.open(w / 'dist/acq-linux-x86_64.tar.gz') as tf:
    identity = {}
    exec(tf.extractfile('py-acq/src/acq_py/_build_info.py').read(), identity)
assert identity['ACQ_VERSION'] == p['acq_version']
assert identity['SOURCE_REVISION'] == p['source_revision']
PY
}

@test "release assets: fake complete dist installs offline and reports the baked Python identity" {
  _build_dist
  run sh "$WORK/dist/install.sh" --source "$WORK/dist" --install-dir "$WORK/installed" --bin-dir "$WORK/bin" --yes
  assert_success
  run "$WORK/installed/acq-python" version --json
  assert_success
  run env ACQ_IMPL=python "$WORK/installed/acq" version --json
  assert_success
  printf '%s\n' "$output" > "$WORK/version.json"
  python3 -I - "$WORK/version.json" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))['data']
assert d['impl'] == 'python'
assert d['acq_version'] == '8.7.6'
assert d['source_revision'] == '0123456789abcdef0123456789abcdef01234567'
PY
}
