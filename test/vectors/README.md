# Test-vector corpus (ADR-0043m)

One immutable UTF-8 JSON file per vector, at `test/vectors/<section>/<id>.json`.
A vector records a single CLI invocation, its expected observable result, and the
isolation it requires. Vectors carry the *what*; the two runners (the pytest
runner and `scripts/run-vectors`) carry the *how*.

> AI-assisted; owner: Bret Mogilefsky.

## Sections

* `cli/` — contract vectors driving the CLI-under-test (`{acq}`).
* `coexistence/` — coexistence-mechanism vectors (ADR-0047m): drive the Bash `acq`
  dispatcher directly (`bash acq …`) to prove the `ACQ_IMPL` runtime switch —
  unset/`bash` runs the Bash body, `python` dispatches to the Python
  implementation, and any other value fails closed.
* `sentinel/` — the golden set proving both runners implement every assertion
  mode and normalisation transform. A diverging runner fails on the feature.
* `negative/` — negative oracles: vectors that require something the foundation
  runner cannot honour and must be *refused* (fail closed) with a stable code.
* `qualification/` — the qualification harness (ADR-0044m): the verbatim `RESULT`
  transcript signature, the first-class `BLOCKED` verdict, the 3-attempt
  reproduction rule, and the honest unqualified-cell matrix. These drive
  `{python} -m qualification` (repo-root tooling, not the `acq` CLI).
* `manifest.json` — the coverage manifest: maps every contract row to at least
  one vector id, and is validated against the corpus in CI (a missing or renamed
  vector fails the check rather than being assumed absent). Its `inventory`
  field points at the legacy-suite retirement classification
  (`docs/test-retirement-inventory.md`), which buckets every legacy
  `test/bats/*.bats` test as preserve/re-express/retire and records the gaps
  (valuable behaviors with no existing vector) as named follow-ups.

## Schema

```jsonc
{
  "schema": 1,               // vector-schema version
  "id": "cli/version-json",  // <section>/<name>, matches the file path
  "oracle": "…",             // the contract row/capability this proves
  "tier": 1,                 // 1 fast/CI, 2 impl, 3 live
  "backend": null,           // sbx|msb|null (non-null needs that backend)
  "platform": "any",         // any|linux|windows|macos
  "invoke": {
    "argv": ["{acq}", "version", "--json"],
    "env": {"ACQ_VERSION": "0.1.0"},
    "unset": ["SOME_VAR"],
    "stdin": "",
    "timeout_ms": 5000
  },
  "expect": {
    "exit": 0,
    "stdout": {"mode": "json", "value": {…}, "normalize": []},
    "stderr": {"mode": "exact", "value": "", "normalize": []}
  },
  "isolation": {
    "offline": true,
    "ssh_stubs": false,
    "redirect": ["HOME", "XDG_CONFIG_HOME"]
  }
}
```

`expect.stdout` and `expect.stderr` each take one assertion object or a
non-empty list of them; every assertion in a list must hold, and each one starts
from the raw stream, so one assertion's transforms never change what the next
one sees. A list pairs a structural check with a never-appears check:
`[{"mode": "json", …}, {"mode": "absent", "value": "<stdin sentinel>"}]`.

Both runners reject a vector with a field the schema above does not define (for
example a typo such as `expect.stdot`, or an `expect.side_effects` block):
it is reported as an invalid vector rather than run with part of its oracle
silently ignored. A missing `value`, an unknown mode or transform, and an empty
assertion list are invalid too.

`invoke.fixtures` and `isolation.no_live_refeed` are enumerated by ADR-0043m but
not implemented; a vector that declares either is refused (fail closed) rather
than silently ignored.

`invoke.fixtures` stays unimplemented on purpose. Every vector that needs prior
state today needs acq state created through acq's own CLI (a stored secret, a
recorded binding, a git workspace), which `drivers/seeded-run.py` produces by
running the earlier acq calls (`["{python}", "-I",
"test/vectors/drivers/seeded-run.py", STEPS, "{acq}"]`; the script documents
the step format, and the coverage manifest records which vectors use it). A
static file fixture could only write acq's on-disk formats directly, which
would tie a language-neutral vector to one implementation's storage layout. Add
`invoke.fixtures` to both runners when a vector needs a fixture that is not acq
state, such as an input file the CLI reads.

Placeholders in `invoke.argv`: `{acq}` splices the CLI-under-test command list;
`{python}` splices the interpreter used by deterministic sentinel subjects.

## Assertion modes (`expect.<stream>.mode`)

* `exact` — byte-exact equality (after transforms). The default.
* `contains` — the expected value is a substring of the output.
* `json` — the output is parsed as exactly one JSON document; `value` must be a
  *structural subset* of it (extra fields are allowed, per ADR-0038m "unknown
  fields are additive"). Booleans equal only booleans (`true` is not `1`). This
  is how a vector asserts the stable envelope fields (`code`, `command`) without
  pinning prose.
* `absent` — the (non-empty) value appears nowhere in the output. `json` and
  `contains` cannot prove that something is missing, so a vector whose oracle
  says a secret never appears pairs its structural assertion with this one. An
  `absent` assertion takes no `normalize` transforms (one could rewrite the
  value it looks for and pass vacuously).

`contains` and `absent` fail output that holds a NUL byte, and their value may
not hold one: the Bash runner's substring search stops at a NUL, so it could not
search past it.

## Normalisation transforms (`expect.<stream>.normalize`, in order)

Exact-by-default: a field is byte-exact unless it declares transforms, and only
declared transforms apply. Regex is not a mode. Placeholders are `<abspath>`,
`<tmpdir>`, `<timing>`.

* `abspath` — replace a POSIX absolute path with `<abspath>`. The path ends at
  ASCII whitespace or a quote. (Windows drive/UNC path normalisation is deferred
  to the platform-qualification slice.)
* `tmpdir` — replace the temporary-directory root with `<tmpdir>`, as literal
  text, longest root first. The roots are `/tmp` and, when it is absolute,
  `$TMPDIR` without its trailing slashes (a relative `TMPDIR` is ignored, as acq
  ignores it); on Windows the interpreter's temp directory replaces `$TMPDIR`.
* `crlf` — normalize CRLF line endings to LF. A CR that is not followed by LF,
  including one that ends the output, is kept.
* `timing` — replace a duration literal (`123ms`, `1.5s`, `150µs`, …) with
  `<timing>`. Both runners match the same duration pattern, including the `µs`
  microsecond suffix.
* `order` — sort the lines of the output by codepoint (byte) order, preserving
  whether the input ended in a newline. Non-ASCII lines are ordered identically
  by both runners.
* `json` — canonical re-serialisation (compact, sorted keys, non-ASCII escaped as
  `\uXXXX`) of output that is exactly one JSON document, `false` and `null`
  included; anything else is left as it is.

The sentinel set shows each mode and transform working; the edge cases where the
two runners once disagreed (a quote ending a path, a lone CR, `true` against `1`,
several JSON documents, a regex character in `TMPDIR`, unknown fields) are
probe vectors under `py-acq/tests/runner-probes/`, which
`py-acq/tests/test_runner_agreement.py` runs through both runners.

## Isolation

`redirect` names environment variables redirected to throwaway directories, so an
oracle can never read or mutate the developer's real state (ADR-0039m); the
runner always redirects `HOME` and the `XDG_*` set. Both runners also remove
`SSH_AUTH_SOCK` before a vector's own `unset` and `env` apply, so a developer's
ssh-agent is never forwarded into a stub sandbox and never changes an oracle
(it is the forward's opt-in, ADR-0021); a vector that needs it sets it in
`invoke.env`. A runner that cannot honour a
declared requirement (`offline: false`, `ssh_stubs: true`, a non-null `backend`,
or an unimplemented `fixtures`/`no_live_refeed`) fails closed with a stable
refusal code (`unsupported_isolation`, `unsupported_backend`, or
`unsupported_vector_field`).
