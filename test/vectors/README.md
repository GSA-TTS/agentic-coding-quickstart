# Test-vector corpus (ADR-0043m)

One immutable UTF-8 JSON file per vector, at `test/vectors/<section>/<id>.json`.
A vector records a single CLI invocation, its expected observable result, and the
isolation it requires. Vectors carry the *what*; the two runners (the pytest
runner and `scripts/run-vectors`) carry the *how*.

> AI-assisted; owner: Bret Mogilefsky.

## Sections

* `cli/` — contract vectors driving the CLI-under-test (`{acq}`).
* `coexistence/` — coexistence-mechanism vectors (ADR-0046m): drive the Bash `acq`
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

`invoke.fixtures` and `isolation.no_live_refeed` are enumerated by ADR-0043m but
not implemented in this slice; a vector that declares either is refused (fail
closed) rather than silently ignored.

Placeholders in `invoke.argv`: `{acq}` splices the CLI-under-test command list;
`{python}` splices the interpreter used by deterministic sentinel subjects.

## Assertion modes (`expect.<stream>.mode`)

* `exact` — byte-exact equality (after transforms). The default.
* `contains` — the expected value is a substring of the output.
* `json` — the output is parsed as JSON; `value` must be a *structural subset*
  of it (extra fields are allowed, per ADR-0038m "unknown fields are additive").
  This is how a vector asserts the stable envelope fields (`code`, `command`)
  without pinning prose.

## Normalisation transforms (`expect.<stream>.normalize`, in order)

Exact-by-default: a field is byte-exact unless it declares transforms, and only
declared transforms apply. Regex is not a mode. Placeholders are `<abspath>`,
`<tmpdir>`, `<timing>`.

* `abspath` — replace a POSIX absolute path with `<abspath>`. (Windows drive/UNC
  path normalisation is deferred to the platform-qualification slice.)
* `tmpdir` — replace the temporary-directory root with `<tmpdir>`.
* `crlf` — normalize CRLF line endings to LF.
* `timing` — replace a duration literal (`123ms`, `1.5s`, `150µs`, …) with
  `<timing>`. Both runners match the same duration pattern, including the `µs`
  microsecond suffix.
* `order` — sort the lines of the output by codepoint (byte) order, preserving
  whether the input ended in a newline. Non-ASCII lines are ordered identically
  by both runners.
* `json` — canonical re-serialisation (compact, sorted keys) of a JSON document.

## Isolation

`redirect` names environment variables redirected to throwaway directories, so an
oracle can never read or mutate the developer's real state (ADR-0039m); the
runner always redirects `HOME` and the `XDG_*` set. A runner that cannot honour a
declared requirement (`offline: false`, `ssh_stubs: true`, a non-null `backend`,
or an unimplemented `fixtures`/`no_live_refeed`) fails closed with a stable
refusal code (`unsupported_isolation`, `unsupported_backend`, or
`unsupported_vector_field`).
