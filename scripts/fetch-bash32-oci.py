#!/usr/bin/env python3
"""Fetch GNU Bash 3.2.57 from Docker Hub's official `bash:3.2.57` image, without Docker.

For Linux sandboxes where GNU mirrors are unreachable and there is no C compiler
(so `scripts/test-acq-bash32 --install` cannot build from source) but the Docker
Hub registry is reachable. Only three files are extracted: the musl loader,
libncursesw, and the bash binary. They run via the loader, so no root, no
container runtime and no system libc dependence.

Integrity chain: the per-architecture MANIFEST digests below are pinned in this
repo; the manifest is verified against its digest, every layer blob is verified
against the digest in the manifest, and the resulting interpreter must report
BASH_VERSION 3.2.57. This is content-addressed integrity, NOT the signer
authentication the source build gets from GNU's OpenPGP signature. It is a
development convenience; the CI gate remains the authoritative check.

Usage: fetch-bash32-oci.py PREFIX      (writes PREFIX/bin/bash, PREFIX/lib/*)
"""
import hashlib
import io
import json
import os
import platform
import shlex
import subprocess
import sys
import tarfile
import urllib.request

REPO = "library/bash"
VERSION = "3.2.57"
# Per-architecture image manifest digests of docker.io/library/bash:3.2.57.
MANIFESTS = {
    "x86_64": ("x86_64", "sha256:1b5d0c83f6f3c7206c16af8f9f4ca08e3eba893c50a80a0ce8b23e7a865136af"),
    "aarch64": ("aarch64", "sha256:eb33603676223a8765da42af35775e9cb68fb831b4903e7bb4c2d35646ef827b"),
}
ACCEPT = "application/vnd.oci.image.manifest.v1+json"
WANTED = {
    "lib/ld-musl-%(arch)s.so.1": "lib/ld-musl-%(arch)s.so.1",
    "usr/lib/libncursesw.so.6.5": "lib/libncursesw.so.6.5",
    "usr/local/bin/bash": "libexec/bash",
}
MAX_BLOB = 64 * 1024 * 1024


def get(url, token=None, accept=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read(MAX_BLOB + 1)
    if len(data) > MAX_BLOB:
        raise SystemExit("fetch-bash32-oci: response from %s exceeds %d bytes" % (url, MAX_BLOB))
    return data


def verified(data, digest, what):
    algo, _, want = digest.partition(":")
    if algo != "sha256" or hashlib.sha256(data).hexdigest() != want:
        raise SystemExit("fetch-bash32-oci: digest mismatch for %s (expected %s)" % (what, digest))
    return data


def check_prefix(prefix):
    """Reject a prefix that cannot be a plain absolute path (before any network or disk work)."""
    if not os.path.isabs(prefix):
        raise SystemExit("fetch-bash32-oci: PREFIX must be an absolute path")
    try:
        prefix.encode("utf-8")
    except UnicodeEncodeError:
        raise SystemExit("fetch-bash32-oci: PREFIX must be valid UTF-8")
    if os.path.normpath(prefix) == "/":
        raise SystemExit("fetch-bash32-oci: PREFIX must not be the filesystem root")
    if "\0" in prefix or any(ord(c) < 32 or ord(c) == 127 for c in prefix):
        raise SystemExit("fetch-bash32-oci: PREFIX must not contain control characters (newline, NUL, ...)")
    return prefix


def launcher_text(prefix, arch):
    """A bash launcher with absolute paths: the interpreter needs its own musl loader and libraries.

    It must be a bash script (not /bin/sh): dash drops exported functions
    (BASH_FUNC_*%%), which bats relies on across nested bash calls. Every path is
    shell-quoted so a prefix with quotes, spaces or `$(...)` runs as literal text.
    """
    loader = shlex.quote("%s/lib/ld-musl-%s.so.1" % (prefix, arch))
    libdir = shlex.quote("%s/lib" % prefix)
    binary = shlex.quote("%s/libexec/bash" % prefix)
    return "#!/bin/bash\nexec %s --library-path %s %s \"$@\"\n" % (loader, libdir, binary)


def main(prefix):
    check_prefix(prefix)
    arch = platform.machine()
    arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(arch, arch)
    if arch not in MANIFESTS:
        raise SystemExit("fetch-bash32-oci: no pinned image for architecture %r" % arch)
    _, manifest_digest = MANIFESTS[arch]
    token_url = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull" % REPO
    token = json.loads(get(token_url))["token"]
    base = "https://registry-1.docker.io/v2/%s/" % REPO
    raw = verified(get(base + "manifests/" + manifest_digest, token, ACCEPT), manifest_digest, "manifest")
    wanted = {k % {"arch": arch}: v % {"arch": arch} for k, v in WANTED.items()}
    found = {}
    for layer in json.loads(raw)["layers"]:
        blob = verified(get(base + "blobs/" + layer["digest"], token), layer["digest"], "layer")
        with tarfile.open(fileobj=io.BytesIO(blob)) as tar:
            for member in tar:
                name = member.name[2:] if member.name.startswith("./") else member.name
                if name in wanted and member.isfile():
                    found[wanted[name]] = tar.extractfile(member).read()
    missing = sorted(set(wanted.values()) - set(found))
    if missing:
        raise SystemExit("fetch-bash32-oci: image lacks expected files: %s" % ", ".join(missing))

    for rel, data in found.items():
        dest = os.path.join(prefix, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.lexists(dest):
            os.remove(dest)
        with open(dest, "wb") as handle:
            handle.write(data)
        os.chmod(dest, 0o755)
    link = os.path.join(prefix, "lib", "libncursesw.so.6")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink("libncursesw.so.6.5", link)

    launcher = os.path.join(prefix, "bin", "bash")
    os.makedirs(os.path.dirname(launcher), exist_ok=True)
    if os.path.lexists(launcher):
        os.remove(launcher)
    with open(launcher, "w") as handle:
        handle.write(launcher_text(prefix, arch))
    os.chmod(launcher, 0o755)

    out = subprocess.run([launcher, "-c", "printf %s \"$BASH_VERSION\""], capture_output=True, text=True, check=False)
    if not out.stdout.startswith(VERSION):
        raise SystemExit("fetch-bash32-oci: installed interpreter reports %r, need %s" % (out.stdout, VERSION))
    print("fetch-bash32-oci: installed %s (bash %s)" % (launcher, out.stdout))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: fetch-bash32-oci.py ABSOLUTE_PREFIX")
    main(sys.argv[1])
