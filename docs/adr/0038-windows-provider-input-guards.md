---
title: "Provider-input path and lock-identity guards on Windows"
description: "Win32 equivalents for the O_NOFOLLOW path walk and the ps-based lock identity"
status: proposed
tier: 2
date: 2026-10-29
last_updated: "2026-10-31"
decision_makers: ["Bret Mogilefsky"]
category: architecture
nist_controls: ["AC-6", "CM-3", "SI-10"]
impact_level: medium
ato_relevance: no
risk_treatment: mitigate
related_files: ["acq.backends/common.sh", "acq.backends/provider_input_pathguard.py", "test/bats/147-provider-input-projection.bats", "test/bats/157-provider-input-pathguard-vet.bats", "test/bats/112-msb-ports.bats"]
---

# ADR-0038: Provider-input path and lock-identity guards on Windows

## Context and problem statement

`acq` guards the host-owned provider-input projection tree by walking a path one
component at a time:

```python
fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
```

That is descriptor-anchored: each component is opened relative to the handle of
the parent that was just vetted, so a symbolic link anywhere in the path is
either refused (`O_NOFOLLOW`) or never reached (`dir_fd`). Its purpose is to
stop a malicious *pre-created* ancestor from redirecting a write.

Native Windows CPython offers none of those primitives. `os.O_DIRECTORY` and
`os.O_NOFOLLOW` do not exist, `dir_fd` is unsupported, and `os.open` cannot open
a directory at all. The transaction wrapper therefore failed at its first step
on Windows (`AttributeError`/`NotImplementedError`), and every `acq terminate`
aborted before port teardown ran. A second, unrelated gap in the same wrapper:
MSYS `ps` has no `-o`, so `ps -o ppid=` and `ps -o lstart=` printed nothing,
leaving the guardian without a transaction parent and without a lock-owner
identity.

## Decision drivers and considered options

- **The traversal invariant is the deliverable.** A `try/except AttributeError:
  os.makedirs(path)` fallback is unacceptable: it silently reintroduces exactly
  the traversal the guard exists to prevent.
- **POSIX must not change.** Linux/macOS keep `O_DIRECTORY`/`O_NOFOLLOW`/`dir_fd`
  byte for byte; no shared abstraction is introduced for symmetry.
- **Fail closed.** Empty or unparsable host output must fail, not degrade.
- **No new dependencies.** Standard library and shell builtins only.

Options considered for the path walk:

1. *`os.path.realpath` + `os.makedirs`* — resolves links, so it cannot detect
   redirection. Rejected.
2. *`os.lstat` on each prefix, then `makedirs`* — check-then-use: the link can be
   swapped between the check and the use, and Windows `lstat` on a path whose
   ancestor is a junction reports the *resolved* object. Rejected as weaker.
3. *Win32 `CreateFileW` per component with `FILE_FLAG_OPEN_REPARSE_POINT`* —
   adopted.

Options considered for the lock identity:

1. *MSYS `STIME`* — one-second resolution, so a recycled PID started in the same
   second is indistinguishable from the original lock owner. Rejected.
2. *procfs `/proc/<pid>/stat` field 22 (starttime ticks)* — the value Linux `ps`
   derives `lstart` from; changes on PID reuse and is stable for the life of the
   process. Adopted.

## Decision outcome

### Path walk (`acq.backends/provider_input_pathguard.py`)

Each component is opened with

```
CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, FILE_SHARE_ALL,
            NULL, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL)
```

- `FILE_FLAG_OPEN_REPARSE_POINT` opens the reparse point itself instead of
  following it — the `O_NOFOLLOW` equivalent.
- `FILE_FLAG_BACKUP_SEMANTICS` is required to obtain a directory handle.

Each handle is then vetted with `GetFileInformationByHandleEx(FileAttributeTagInfo)`:

- `FILE_ATTRIBUTE_REPARSE_POINT` set -> reject (symbolic link, junction, or
  volume mount point).
- `FILE_ATTRIBUTE_DIRECTORY` clear -> reject (the `O_DIRECTORY` check).

The handle's own resolved name (`GetFinalPathNameByHandleW`) must be a *direct
child* of the parent handle's resolved name. That is the descriptor-relative
walk's anti-TOCTOU property expressed as an identity check: a child that resolves
anywhere but directly under the vetted parent means an ancestor was replaced
between the parent being vetted and this open, and it is rejected.

Comparison semantics, in order:

1. Reparse-point and directory attribute checks run first and are unaffected.
2. The resolved name has its `\\?\` / `\\?\UNC\` prefix stripped
   (case-insensitively) and is split into parent and last component with
   `ntpath`. Windows path logic uses `ntpath` explicitly, because `os.path` is
   `posixpath` on any other host and would give the wrong answer there.
3. The resolved parent, case-folded and normalized, must equal the vetted
   parent's resolved name. A different parent, another volume or server, a
   shallower or deeper result, the parent itself, or a `.`/`..` component is
   rejected, as is a last component containing `:` (an alternate data stream).
4. The last component is deliberately *not* compared with the literal spelling.
   For an 8.3 alias such as `C:\PROGRA~1` or `C:\Users\RUNNER~1`, the kernel
   reports the long name (`Program Files`, `runneradmin`), so a textual match
   would reject a legitimate path. An alias is accepted only when what it
   resolves to sits directly under the vetted parent; an alias that resolves
   elsewhere fails step 3. A literal and its resolved leaf may therefore differ
   (short vs long name, trailing dots or spaces that Win32 strips, case) while
   still naming a child of the same vetted parent.
5. A trailing separator on the parent (a drive or share root) is ignored when
   comparing. A `:` in any *input* component is rejected up front, because
   `ntpath.join` would otherwise read it as a drive or stream.

Missing components are created with `CreateDirectoryW`, which inherits the
parent ACL — the Windows analogue of the POSIX `0o755` mkdir honouring umask.
There is no other failure recovery: `UnsafePath` maps to the same `SystemExit`
payload the POSIX path produces (`'provider-input path must be absolute'`,
`'unsafe provider-input path'`, or a silent `1` for the check-only variant).

The drive/UNC anchor is opened *without* the reparse-point rejection, mirroring
the POSIX walk that opens `/` without `O_NOFOLLOW` and canonicalizes only
OS-level aliases such as macOS `/var` -> `/private/var`.

### Path spelling (why the shell translates)

The MSYS runtime rewrites POSIX-looking argv values on their way to a native
program, and that rewrite canonicalizes: it *resolves* junctions and symlinks. A
guard fed the rewritten value could no longer tell a pre-created link from a
legitimate directory, so it would honour the redirect instead of refusing it.

The shell therefore builds the Windows spelling itself
(`_acq_provider_input_windows_path`) and passes it as argv, because an
already-drive-form argv value passes through MSYS unchanged. The mount table
(`/proc/mounts`, which MSYS/Cygwin owns) is the authority: the longest mount
point that prefixes the path is replaced by its Windows spelling, and everything
below it is appended verbatim. Only the mount point is canonicalized — the
analogue of macOS `/tmp` -> `/private/tmp` — and no component below it is touched,
which is what keeps an unresolved `link/child` intact.

`cygpath` is deliberately not used even though the codebase uses it elsewhere for
host/guest forms: `cygpath` resolves links *inside* the path, which is precisely
the information this guard needs to keep. Reading the mount table answers the
same question without that resolution, and keeps the guard working under the
suite's fake-`cygpath` stubs, which implement only the options acq's other
callers need.

A relative path is handed on unchanged so the guard rejects it with the same
message POSIX prints.

### Process identity and transaction parent

`_acq_provider_input_parent_pid` keeps `ps -o ppid=` first and falls back to
parsing `ps -p PID`, whose BSD layout (`PID PPID PGID WINPID TTY UID STIME
COMMAND`) is what MSYS provides. The row is selected by exact PID match, so the
fallback is correct with or without the header line, and an empty or non-numeric
result fails closed exactly as before.

`_acq_provider_input_process_identity` keeps `ps -o lstart=` first and falls back
to `/proc/<pid>/stat` field 22. Field 2 (`comm`) may contain spaces and
parentheses, so the line is split after the last `)`.

## Consequences and validation

- POSIX hosts execute the original code path unchanged: the Windows branch is
  gated on `sys.platform == 'win32'` inside the same heredoc, and the shell only
  computes a Windows spelling when `uname -s` says MSYS/Cygwin.
- Windows is slightly *stricter* than POSIX: a volume mount point below the drive
  root is rejected where POSIX would accept a bind mount. That is the
  fail-closed direction.
- Residual race: the walk holds a vetted parent handle but Windows has no
  Win32-level "open relative to this handle" call, so a component is opened by
  name and the final-path check happens after that open. An attacker who can
  rename inside the tree *while* the walk runs could therefore still race a
  rename-then-rename-back. The pre-created-ancestor threat this guard was written
  for is fully covered; closing the concurrent-rename window would require
  `NtCreateFile` with a root-directory handle, which is undocumented API and not
  justified here.
- Not covered by this ADR: `_acq_provider_input_snapshot` still opens the fetched
  kit with `O_DIRECTORY`/`O_NOFOLLOW` and walks it with `dir_fd`. It is on the
  provider-input *staging* path, not the transaction path, and is documented as a
  known Windows gap rather than fixed here.

Component vetting is also covered offline on any host by
`test/bats/157-provider-input-pathguard-vet.bats`, which drives the real walk over
a fake volume of literal-to-resolved names: 8.3 aliases (first, mid-path, UNC),
case-only differences, redirects to another parent/volume/server, `..` and
alternate-data-stream results, reparse points (including behind an alias), and
non-directories. That proves the comparison logic only; it cannot prove what a
real Windows volume reports for a short name, which needs a Windows host with 8.3
name generation enabled.

Regression coverage lives in `test/bats/147-provider-input-projection.bats`
(pre-created link ancestor rejected with no mutation on the far side, link as
final component rejected, relative-path diagnostic, guardian parent pid, identity
stability and fail-closed behaviour) and `test/bats/112-msb-ports.bats` (the
teardown that exposed the bug). The link tests choose the host's own link
mechanism — POSIX symlink or Windows junction — so a single shared invariant is
asserted everywhere instead of a Windows-only truth.

Rollback deletes `acq.backends/provider_input_pathguard.py` and the two
`sys.platform == 'win32'` branches in `acq.backends/common.sh`; the POSIX code is
untouched and needs no restoration.
