# acq-py — Python implementation of acq v1 (in progress, not at parity)

This directory is the Python replacement for the repo-root Bash `acq` wrapper.
It implements every subcommand the Bash `acq help` lists, on both backends (msb
and sbx). It is **not yet at parity** with Bash, and it is **not currently
Tier-3-qualified**. One documented flag is still missing: `--clone` on
`run`/`create`. `ACQ_CLONE=1` is refused with a usage error rather than
mounting the real workspace. Some behaviour also differs; for example,
a kit outside the pinned built-in bundle is applied only when its ref is pinned
to a full commit, and a local kit directory is copied into acq's private cache
and checked there before it is applied. The dated correction in
ADR-0047m lists the gaps and the qualification state. The Bash `acq` stays the default implementation
(`ACQ_IMPL` unset); `ACQ_IMPL=python` selects this one.

> AI-assisted; owner: Bret Mogilefsky.

## Layout decision and coexistence plan

The new code lives under `py-acq/` (package `acq_py`, console script `acq-py`);
the language-neutral test corpus lives under `test/vectors/`; the Bash vector
runner is `scripts/run-vectors`. The Python code keeps out of the legacy tree.
The Bash implementation is still maintained beside it, and the `ACQ_IMPL` switch
in `acq` (ADR-0047m, described below) selects between the two:

| Path | Legacy | New (Python v1) |
|------|--------|-----------------|
| `acq`, `acq.backends/`, `scripts/*` (except `run-vectors`), `test/bats/` | shipped Bash CLI + suite, still maintained | none, apart from the `ACQ_IMPL` switch in `acq` |
| `py-acq/` | — | Python package + pytest runner |
| `test/vectors/` | — | language-neutral corpus + manifest |
| `scripts/run-vectors` | — | Bash vector runner |
| `.github/workflows/python-vectors.yml` | — | vectors CI lane |

The Python console script is named `acq-py` during coexistence. When the Python
implementation reaches feature parity, the `acq` name transfers to it and the
Bash wrapper is retired (the "cutover" slice). ADR-0041m is explicit that v1
replaces Bash and maintains no coexistence guarantee; this naming defers that
rename so the two can never collide on a user's `PATH`.

The coexistence mechanism (ADR-0047m) adds a runtime switch on the repo-root
Bash `acq`: `ACQ_IMPL=python` resolves and execs this Python implementation, so
the two can coexist behind one `acq` name. The Python implementation also has a
distinct, installer-linked identity — an `acq-python` launcher that runs the
managed runtime `python -m acq_py` against `py-acq/src` — so it is resolvable
without ever taking the `acq` name. `version` reports `"impl": "python"` for
unambiguous bug reports.

## Quick start

```text
python -m pip install ./py-acq          # no runtime dependencies
acq-py version --json
```

```text
{"schema_version": 1, "command": "version", "data": {"acq_version": "0.1.0", ...}}
```

Or run from source without installing:

```text
PYTHONPATH=py-acq/src python -m acq_py version --json
```

## The CLI

* `acq-py version` — human version/identity output (ADR-0042m): the acq
  version and source revision, the active backend (resolved as for every other
  verb, `--backend` included) with its detected version, and the pinned
  control-plane ref. Read-only: it never applies the version floor, and an
  unknown backend pinned in config.yaml is a warning.
* `acq-py doctor` — human diagnostic output (ADR-0038m §doctor): an overall
  `status` plus a check list, each with a stable `id`, `status`, `message`, and
  optional `remediation`. In this slice the checks are `runtime` (managed-runtime
  resolution, ADR-0042m) and `backend` (adapter availability, ADR-0040m).
* `acq-py version --json` and `acq-py doctor --json` (and `acq-py --json version`
  / `acq-py --json doctor`) — the structured-output envelope (ADR-0038m §2):
  `{"schema_version", "command", "data"}` on success,
  `{"schema_version", "command", "error": {"code", "message", "remediation?"}}`
  on failure. One document on stdout; diagnostics on stderr.
* `acq-py backend list [--json]` — detected backends (sbx/msb) with
  `active_backend` plus per-backend `name`/`installed`/`version` records
  (ADR-0038m §2). Read-only: an unknown/unparseable version reports `"unknown"`
  and never fails the query.
* `acq-py backend check NAME [--json]` — the version floor, fail closed
  (ADR-0040m): exit `0` when `NAME` is installed and supported, else exit `1`
  with `backend_not_found`, `backend_version_unsupported`, or
  `backend_version_unknown`. No mutation occurs.
* `acq-py create AGENT PATH [--name N] [--image REF] [--json]` — create a sandbox
  (detached) through the MSB adapter, wait for exec-readiness, and record a
  host-authoritative state record carrying `schema=N` (ADR-0041m).
* `acq-py create --recreate NAME [--yes] [--json]` — the security-exception
  recreation (ADR-0035/0041m): recreate a sandbox whose read-only trusted-config
  mount is missing. Explicit and consent-gated — a non-interactive run without
  `--yes` refuses with `consent_required`; host records and secrets are
  preserved, only the guest filesystem is lost.
* On msb, `create` applies the same deny-by-default egress policy as the Bash
  acq (`ACQ_NETWORK_TIER`, see `docs/BACKEND_GUIDE.md`). **Upgrade note:** msb
  fixes a sandbox's network rules at create, so a sandbox the Python acq created
  before it applied this policy keeps unrestricted egress through `start`,
  `restart` and `run NAME`. Remove it with `acq-py rm NAME` and create it again
  to apply the policy (`create --recreate` does not cover this case). See
  KNOWN_FAILURE_MODES, "Python acq on msb: Egress Policy Requires Recreation".
* The read-only trusted-config mount (ADR-0035) is msb-only, and POSIX-only. On
  Linux and macOS with msb 0.7.7 or later, create mounts the sandbox's
  host-config directory `:ro` and records `ro_host_config` once `msb inspect`
  and a guest probe confirm it; with an older msb, recreate refuses until msb
  is upgraded. On Windows, msb's filesystem backend was not reviewed for
  read-only enforcement, so acq never asks for the mount there: sandboxes are
  created without it, and `create --recreate` rebuilds a sandbox the same way
  a fresh create would (`"ro_host_config": false`) instead of refusing or
  looping. See KNOWN_FAILURE_MODES §54.
* `acq-py run AGENT PATH [--name N] [--image REF] [--json]` — create (if missing)
  then launch the agent in the foreground; `acq-py run NAME` re-attaches to an
  existing sandbox by name.
* Stale-sandbox check (ADR-0016, Bash `maybe_offer_bundle_refresh`): when `run`
  re-attaches, acq compares the kit bundle the sandbox recorded (read before
  the re-attach heal) with the pinned one. Exact-ref, local only: no network.
  A `stale` or `unknown` bundle gets a note on stderr. Without a terminal on
  stdin, or under `--json`, the note says how to refresh later (`acq kit update
  NAME`) and the launch goes on. At a terminal acq asks `[y/N]`; only `y`/`yes`
  refreshes (the `kit update` reapply, under the lifecycle lock, after the
  question), and a failed refresh is a warning, never a failed launch.
  `--no-update-check` (on `run`, and accepted on `create` as in Bash) or
  `ACQ_UPDATE_CHECK=0` skips the check; only the value `0` turns it off. As in
  Bash, `ACQ_NO_PROMPT` does not silence this question; only a terminal on
  stdin and `--json` decide it.
* Clone mode (ADR-0027) is not ported yet, and `create`/`run` fail closed
  rather than mount the real workspace: `--clone` is an unrecognized argument,
  and `ACQ_CLONE=1` is refused with a usage error (exit 2) before any state or
  backend access, on every `create`/`run` form, re-attach included. Only the
  exact value `1` refuses, as only `1` turns clone mode on in Bash; any other
  value, empty included, is off and ignored. Unset `ACQ_CLONE`, or use the Bash
  implementation (`ACQ_IMPL=bash`) for a disposable clone. See
  KNOWN_FAILURE_MODES, "Deferred: the Python acq has no clone mode".
* Sandbox names and workspace paths follow the Bash `acq` rules
  (`commands/common.py`). Without `--name`, the name is `AGENT-<slug>`, where the
  slug is the lowercased ASCII letters and digits of the workspace's last path
  component (the root gives `workspace`). An explicit `--name` must match
  `[A-Za-z0-9_-]+` and not start with `-`. Verbs that act on an existing sandbox
  (`stop`, `start`, `restart`, `rm`, `exec`, `attach`, `shell`, `ports`,
  `kit apply|check|update`, `create --recreate`) refuse an empty name, `.`,
  `..`, and names containing `/`, `\` or control characters. A workspace path,
  and the path its symlinks resolve to, must not contain control characters or
  `:`. The backends split mount specs on `:`, and acq-py takes no `:ro` suffix.
  On Windows the colon of a drive letter (`C:\...`) is allowed, because msb's
  `--volume` source accepts it.
* `acq-py ls [--json]` — list sandboxes with `name`/`backend`/`state`
  (ADR-0038m §2). A backend listing that fails makes `ls` fail (`failure`);
  only a successful empty listing reports no sandboxes.
* `acq-py stop NAME [--json]` and `acq-py rm NAME [--json]` — stop (state
  preserved) or remove a sandbox and its record.
* `acq-py start NAME [--json]` and `acq-py restart NAME [--json]` (msb only) —
  resume a stopped sandbox (`restart` stops it first; a failed stop only warns),
  under the sandbox's lifecycle lock. `msb start` gets the sandbox's bound
  secrets from the acq store in its environment only (msb keeps no value across a
  stop); a recorded binding with no readable value is refused before anything
  starts. Once the guest is exec-ready, a secret stored while it was stopped is
  bound with `msb modify`, the read-only trusted-config mount is checked when the
  record requires it, and the kit set (the recorded agent, image and `.kits`
  refs) is re-applied so kit startup runs again (ADR-0017). Any failure after
  the start says the sandbox is running and exits 1. On sbx both fail with
  `unsupported_capability` and point to `acq run NAME`.
* `acq-py [--json] exec NAME -- CMD...` — run a command non-interactively inside
  a sandbox as the unprivileged `agent` user; the child's exit status is acq's
  exit status (ADR-0038m §1). In `--json` mode the child's stdout is routed to
  stderr and one success envelope carrying `exit_code` is emitted on stdout.
  acq's own flags go before `NAME`: everything after it, including `--json` or
  `--backend`, is the guest command.
* `acq-py attach NAME [--json]` — attach to an existing sandbox, launching the
  recorded agent. The agent is read from host-authoritative state only; there is
  no agent-to-shell fallback (ADR-0038m §48). The non-interactive contract is
  deterministic: fail closed on a missing sandbox or a missing/unreadable host
  record, propagate status.
* `acq-py shell NAME [--json]` — open a shell in a sandbox: on msb the agent
  user's passwd shell as a login shell, on sbx `bash`.
* Sessions: when stdin is a terminal, `attach`, `shell` and `run` give the
  session a PTY (`msb exec -t`, `sbx exec -it`) and pass the host's `TERM` and
  `COLORTERM`; without one there is no PTY. Every session (`exec` too) gets
  `HOME=/home/agent` and the host git identity (`GIT_AUTHOR_*`,
  `GIT_COMMITTER_*`, and `EMAIL` or the global `user.email`). On msb, `attach`,
  `shell` and `run` also get `SHELL`, with or without a PTY; sbx templates set
  their own. `SSH_AUTH_SOCK` is passed only when the sandbox records a forwarded
  ssh-agent socket, never the host's own. A child killed by signal N gives exit
  status `128+N`. Ctrl-C goes to the child rather than killing it; when the
  child dies of a Ctrl-C that acq received too, acq dies of SIGINT as well, so a
  calling shell loop stops, and under `--json` no envelope is printed. A SIGINT
  sent only to the child gives an ordinary `130` with the envelope. A SIGTERM
  or SIGHUP sent to acq during a session is passed on to the child, which has
  ten seconds to exit before acq kills it; acq then exits `128+N` with no
  envelope, so the session never outlives acq holding the terminal. On Windows
  a Ctrl-Break reaches the child from the console itself; acq gives it the same
  ten seconds and exits `149` (SIGBREAK is 21), again with no envelope. A
  forced kill of acq on Windows (`taskkill /F`, End task) runs no handler, but
  the session runs in a Job object that closes with acq, so the session and
  what it started end too (KNOWN_FAILURE_MODES §85).
* Flag position: acq's own flags (`--json`, `--backend NAME`) may go anywhere
  before `--` for most verbs, so `acq ls --json` and `acq attach box --json`
  work. Only two places are strict: after the `exec` sandbox name, where tokens
  are the guest command (and `acq exec NAME --json -- CMD`, with nothing but
  acq flags before `--`, is refused as a usage error), and after a passthrough
  verb, where everything is forwarded to the backend.
* `acq-py cp SRC DST [--json]` — copy between a native host path and a POSIX
  guest path. Exactly one side is a `NAME:/guest/path` reference; host and guest
  types stay distinct (ADR-0038m §4). The host side is forwarded verbatim to the
  backend, which resolves it natively on the host, so a UNC/network host path
  (`\\server\share\...` / `//server/share/...`) is accepted the same way a
  plain-drive path is — consistent with the UNC workspace mount (ADR-0029).
  The `msb copy` status is preserved.
* `acq-py ports NAME [--json]` — report a sandbox's *declared* host/guest port
  mappings with origin (`create` for a create-time `-p` mapping, `post-hoc` for
  a tunnel `ports --publish` opened), never listener health (ADR-0038m §2). A
  failed or unreadable `msb inspect` fails closed rather than reporting an empty
  list (ADR-0038m §48).
* Published ports (ADR-0014, ADR-0034, `acq_py/publish.py`). On msb, every
  kit's `publishedPorts` become `msb create -p HOST:GUEST` flags, unioned by
  guest port (last wins). A kit port with no `host:` gets a free loopback port
  chosen per sandbox (20000-59999, probed by connecting to `127.0.0.1`), so two
  sandboxes from one kit do not collide. `create`/`run` `--publish HOST:GUEST`
  (repeatable, `--publish=HOST:GUEST` too) overrides a kit's host port for that
  guest port, or publishes a guest port no kit declares, with a note. Values
  follow the Bash rules: both sides, digits only, no leading zero, 1..65535,
  one host port per guest port; a bad value is `validation_failed` (exit 1)
  and creates nothing. A requested host port that is in use, or requested
  twice, fails the create: acq never substitutes another port. When the probe
  cannot tell (neither a connection nor a refusal), the port is published with
  one note. On sbx, `--publish` is refused with `unsupported_capability`,
  because sbx picks the host port itself. It is create-time only: a re-attach
  (`run AGENT` on an existing sandbox, `run NAME`) notes that it is ignored, and
  `create --recreate --publish` is a usage error; a recreate keeps the old
  guest's create-time mappings. The create/run JSON carries `ports`. Kits that
  declare `volumes:` are still refused on msb.
* `acq-py ports NAME --publish HOST:GUEST [--json]` (ADR-0015) — on msb, open a
  tunnel to a running sandbox: an acq-managed ed25519 key under
  `ACQ_STATE_DIR/ssh` (made with `ssh-keygen` once, authorized with `msb ssh
  authorize` on every publish), `msb ssh serve` on a loopback port, and an
  OpenSSH `-L` forward with Bash's options (only the acq key, no user ssh
  config, no interactive auth). Both run in the background; acq checks that
  each stayed up and that the host port listens, and records them in
  `ACQ_STATE_DIR/ports/NAME.pids` in the Bash format, so either implementation
  lists and tears down what the other opened. `stop`, `restart` and `rm` stop
  them. Each repeated `--publish` is opened, all or nothing (Bash kept only the
  last); values are checked first, and a `--publish` with no value is refused
  rather than read as a listing. On sbx the values go to `sbx ports NAME
  --publish` verbatim and its status is kept. Needs the OpenSSH client
  (`ssh`, `ssh-keygen`) on the host.
* `acq-py secret set (-g | SANDBOX) SERVICE [--host HOST --env ENV] [--json]` —
  store a secret in the acq secret store, which is shared byte for byte with the
  Bash `acq` (`acq_py/secretstore.py`: macOS keychain, `secret-tool`, Windows
  DPAPI, or a 0600 file that is never used on Windows), then feed it to the
  backend on its stdin. The value never appears in argv or output; the success
  envelope reports `scope`/`scope_kind`/`service`/`value_state` only (ADR-0038m
  §secret set; `scope_kind` is described below).
  A scope-less `secret set` is a usage error (ADR-0038m §48 drops scope-less
  secret set). An empty or whitespace-only value, a value with a newline or tab
  (after one terminal newline, plus a CRLF `\r`, is stripped), or input that is
  not valid UTF-8 is a `validation_failed` failure (exit 1) and nothing is
  stored. Service and sandbox names must match `[A-Za-z0-9_-]+` and not start
  with `-`; a sandbox named `global` is a sandbox scope. `--host`/`--env` record
  a custom endpoint and must be given together (`--host` alone works for a
  service with a known env var).
  **On sbx:** only sbx's built-in services (`anthropic`, `github`, `gitlab`,
  `google-cloud`, `openai`, `aws`, `azure`) go through `sbx secret set
  [--sandbox S] SERVICE`. Every other endpoint is a custom secret bound to its
  hosts and env var with `sbx secret set-custom [--sandbox S] --host H… --env E
  --value-stdin`, which needs sbx 0.51.0 or newer (older fails with
  `backend_version_unsupported` before anything is stored): `usai` (bound to
  `api.gsa.usai.gov` as `USAI_API_KEY`), a provider pinned with `acq
  provider-credential set` (every pinned host), and any explicit `--host`, built-in
  names included. A service that is neither is refused with `validation_failed`,
  since sbx would store it and never inject it. An entry sbx already holds for that
  scope is refused too (sbx would prompt to overwrite and eat the piped value).
  **Typing a secret:** on a terminal the value is read with echo off after a
  prompt on stderr. Under Git Bash/mintty, native Windows Python sees a pipe
  rather than a console, so typed input cannot be hidden: acq prints a warning
  first. There, pipe the value instead (`printf '%s' "$TOKEN" | acq-py secret
  set -g usai`) or run from a native console (Windows Terminal, PowerShell, cmd).
* `acq-py secret import [SERVICE] [-g | SANDBOX] [--all] [--force] [--dry-run]
  [--json]` — copy known tokens from the host environment (`USAI_API_KEY`,
  `GITHUB_TOKEN`/`GH_TOKEN`, `GITLAB_TOKEN`, registered provider KEY_ENVs) into the
  acq secret store, as Bash `acq secret import` does. Needs no backend.
  Interactive by default (asks per service on a terminal, skips otherwise);
  `--all` never overwrites, `--force` does, `--dry-run` writes nothing.
* `acq-py secret rm (-g | SANDBOX) SERVICE [--accept-unconfirmed NAME[,NAME]]
  [--json]` — remove a secret. An absent secret fails closed with the
  `secret_missing` code; a backend that cannot answer fails closed with its
  accurate code (`backend_not_found`/`failure`) and never deletes (ADR-0040m).
  On msb the secret is first unbound from every sandbox acq recorded as holding
  it, and swept best-effort from sandboxes acq has no record for (created by the
  Bash `acq` or by `msb` directly). If a binding cannot be removed, or an
  unrecorded sandbox cannot be confirmed unbound, the secret is kept and the
  command fails with `unbind_failed`, naming the sandboxes.
  `--accept-unconfirmed NAME[,NAME]` (msb only) accepts the named unrecorded
  sandboxes staying unconfirmed: the removal then succeeds, the JSON data lists
  them under `unconfirmed`, and a note on stderr says they may still hold the
  binding. It never covers a recorded binding that failed. It is a stopgap
  until a live msb check settles what removing an unbound variable does (see
  `docs/KNOWN_FAILURE_MODES.md`), and can be retired then.
  On sbx a built-in is removed by name and a custom secret by the placeholder
  found for its env var (`sbx secret rm --placeholder P -f`); a single bare token
  is a raw placeholder. Every sbx removal passes `-f` with stdin closed, so sbx's
  confirm prompt never waits unseen.
* `acq-py secret ls [(-g | SANDBOX)] [--json]` — list secrets with
  `scope`/`scope_kind`/`service`/`value_state` (set/unset) only, never a value
  (ADR-0038m §2 secret ls required data). On sbx a custom secret is listed by its
  env var. An unreadable, wrong-shape document, or wrong-shape *entry* fails closed
  with `secret_unreadable` — never silently dropped (ADR-0040m, ADR-0038m §48).
* **`scope_kind`** (added alongside `scope` in the `secret set`/`rm`/`ls`/`import`
  JSON; `scope` itself is unchanged): `scope` reads `global` both for the global
  scope and for a sandbox named `global`, so `scope_kind` says which: `global` or
  `sandbox`. `secret ls` can also report `unknown` where the backend's own listing
  cannot tell: sbx's `secret ls --json` labels both scopes `global`, so once sbx
  has a sandbox named `global` such an entry is `unknown`; a legacy dotted
  acq-store key (`scope` `?`) is `unknown` too. On sbx, `secret has`/`rm` and
  `secret set`'s existence check fail closed where they would need to tell those
  two scopes apart (a native entry is still removed, by an argv that names the
  scope). Rename such a sandbox to avoid the ambiguity.
* `acq-py secret has (-g | SANDBOX) SERVICE` — a silent predicate (ADR-0038m):
  exit `0` when the secret is present, `1` when absent, `2` on a usage error. On
  sbx "present" means sbx can inject it: a built-in by its native entry, any other
  service by its custom secret's env var (`usai` by `USAI_API_KEY`), and a sandbox
  scope falls back to the global entry sbx also injects there. It
  prints nothing on stdout, even with `--json`. A backend that cannot answer (an
  unsupported backend, or a query failure) still exits `1` with stdout silent but
  announces a diagnostic on stderr so "cannot check" is not a silent false
  "absent".
* Any other subcommand is forwarded verbatim to the active backend binary with an
  announced stderr notice, preserving its exit status (ordinary-user story 9 in
  `docs/spec/acq-v1.md`).
  Everything after the verb is forwarded, so acq's `--json`/`--backend` must
  come before it.
* Exit codes (ADR-0038m §1): `0` success, `2` usage, `1` operational. A
  well-formed command acq cannot carry out (for example `doctor NAME` while no
  backend adapter is present) fails closed with exit `1` and the
  `unsupported_capability` code (ADR-0040m). The lifecycle verbs add
  `sandbox_not_found`, `sandbox_exists`, `validation_failed`, and `timeout`; the
  secret verbs add `secret_missing`, `secret_unreadable` and `unbind_failed`; the state-migration
  slice adds `state_schema_unsupported` (a newer/unparseable/`min_reader`
  record), `migration_locked` (the migration lock was held by a concurrent
  invocation), `migration_failed` (an atomic record migration could not verify),
  and `security_exception` (a sandbox missing its read-only mount).
  `exec`, `attach`, `shell`, `cp`, and passthrough preserve the child/backend
  exit status rather than acq's own `0`/`1`.

## configure (ADR-0031)

`acq-py configure` ports the Bash `acq configure`. It first prints the current
settings (to stderr, in the Bash layout). At a terminal it then asks the Bash
questions with the Bash defaults (opt-in kits, the GitHub-token scoping default,
the provider kit) and writes the same three `config.yaml` keys through
`acq_py/config.py`: `extra_kits`, `scope_github_token` and `provider_kit`. Other
keys, including unknown ones, are kept. Without a terminal (or with
`ACQ_NO_PROMPT`, `ACQ_NO_PROGRESS` or `--json`) nothing is written; `--json`
lists each setting as `key`, `value`, `source` and `honoured_by_python`.

The Python acq reads all three keys at `create` and `run`, with Bash's
precedence, so `--json` reports `"honoured_by_python": true` for each:

* **`extra_kits`** is used unless `ACQ_EXTRA_KITS` is set and non-empty; `--kit`
  refs are added after either. An unknown name in `extra_kits` stops the create.
* **`provider_kit`** is the provider kit unless `--no-provider-kits` is given or
  `ACQ_PROVIDER_KITS` is set (an empty value selects no provider kit). The flag
  wins over both and needs no provider credential. The create records which of
  these applied (`provider_selection` and `provider_kits`, as Bash records them),
  and `start`, `create --recreate` and `kit update` use that record instead of
  the selection current at the time, so a sandbox created without provider kits
  never gains a provider key or kit later. A sandbox with no recorded selection
  (one from before acq recorded it) uses the current selection; Bash uses the
  default selection there. Records the Bash acq wrote are carried over by the
  state migration.
* A kit the built-in bundle does not hold (every catalog extra kit, a provider
  kit from a registered source) is fetched at its pinned commit (see "Kits
  outside the bundle" below), and a local kit directory is copied and checked
  first. A ref not pinned to a full commit is refused at create and needs the
  Bash acq (`ACQ_IMPL=bash`). `--json` marks these two settings
  `"python_applies": "pinned-only"`.
* **`scope_github_token`** is the default answer (`yes`, `y` or `Y` mean yes)
  to the per-sandbox GitHub-token prompt (ADR-0013). Before a new sandbox is
  provisioned, and when `run` re-attaches, acq checks the workspace for GitHub
  repositories. If it finds some and the sandbox has no token of its own, it
  says so on stderr and asks "Scope a GitHub token for this sandbox now?". A
  yes runs the `github-scope` steps; it stores the token before the create, so
  msb binds it. Declining, an empty token or a multi-owner workspace never stops
  the create.

  Without a terminal on stdin, both implementations print only the
  `acq github-scope SANDBOX PATH` command to run later. Python also does that
  under `--json` (stdout stays one document), and at a terminal when
  `ACQ_NO_PROMPT` or `ACQ_NO_PROGRESS` is set. That last case is the one
  difference from Bash, which then takes the configured answer without asking
  and, on `yes`, reads a token from the terminal. Python never reads a token
  while prompts are off.

Deliberate differences from Bash:

* **Schema marker.** A `config.yaml` that Python creates starts with `schema: 1`
  (ADR-0041m); Bash's writer never adds it. An existing file is changed only in
  the keys written, and only after the forward migration, which runs just before
  the first write (so cancelling leaves a legacy file untouched) and refuses a
  newer schema up front.
* **Offline provider list.** The provider-kit picker offers the shipped default
  and the provider kits Python already knows about (the control plane's, and any
  a registered source is known to publish). It never fetches a kit source, so it
  can list fewer kits than Bash, which fetches every trusted source.
* **Layer reporting.** The report shows the value Python would use, with its
  layer: `--backend` (flag), `ACQ_BACKEND`, `ACQ_EXTRA_KITS`, `ACQ_PROVIDER_KITS`
  and `ACQ_PROVIDER_CREDENTIAL_BINDINGS` (env), the config, or the default. Bash
  shows only `config.yaml`. Kit sources and provider-credential bindings come
  from Python's own registries, and each binding carries its own layer. The
  human report marks a flag or env value with `[from X]`; otherwise it matches
  Bash line for line, plus a note that extra and provider kits apply only from
  the built-in bundle or pinned to a commit. Userinfo in a kit ref
  (`https://user:token@host`) is shown as `***@host`.
* **Stricter failures.** A `config.yaml` write that fails exits 1 (Bash ignores
  it), a malformed `ACQ_PROVIDER_CREDENTIAL_BINDINGS` is `validation_failed`, and
  an unknown `--backend` is a usage error. Ctrl-C exits 130; SIGTERM and SIGHUP
  restore the terminal and exit 128 plus the signal number.
* **Not ported.** The create-time kit picker (an accepted gap in ADR-0048m).

**First-run offer** (Bash `maybe_first_run_configure`). Before a new sandbox is
created (`create`, or `run` creating one) and while there is no `config.yaml`,
acq says it looks like a first run and asks "Configure extra kits and token
scoping now? [Y/n]". Yes (or Enter) runs the `configure` flow above and the
create goes on; no writes `backend: <the resolved backend>`, so the offer is
not repeated. It is asked only where configure's prompts are: stdin a terminal
(a real console on Windows), `ACQ_NO_PROMPT` and `ACQ_NO_PROGRESS` unset, and
never under `--json`. Unlike Bash, `create` of a sandbox that already exists
does not ask (it is refused anyway), and an interrupted configure (Ctrl-C, or
SIGTERM in key mode) stops the create.

## State migration (ADR-0041m)

acq owns migration of acq-hosted state records; backend-native state is never
migrated, and guest-writable state is never trusted. Before any mutating verb,
acq runs a synchronized forward-migration pre-step under an exclusive OS advisory
lock (`flock`/`fcntl` on POSIX, `msvcrt.locking` on Windows) that auto-releases on
crash: legacy v0 records migrate forward in place, a single tree-level generation
marker is written LAST so a partial migration is resumable, and a newer or
unparseable record (or a reader below a record's `min_reader`) is refused with a
stable code. Each record migrates atomically and non-destructively until
verified. Read-only diagnostics (`ls`, `doctor`) report rather than migrate.

The version floor is checked against the program the adapter actually runs, so
an `ACQ_MSB_BIN`/`ACQ_SBX_BIN` override is probed with `--version`/`version` and
refused before any mutation when it is below the floor. Detection and the
reported version are overridable for reproducible, offline tests:
`ACQ_SBX_INSTALLED`/`ACQ_MSB_INSTALLED` (`"0"`/`"1"`) and
`ACQ_SBX_VERSION`/`ACQ_MSB_VERSION` (a forced version string). `"0"` (force
absent) is honoured everywhere; `"1"` and a forced version are honoured only
while that backend's `ACQ_*_BIN` is `__stub__`, so they can never skip the floor
for a real binary.

## Managed runtime (ADR-0042m)

**Supplier (settled):** Python.org embedded on Windows; python-build-standalone
install-only archives on macOS and Linux. An IT-approved base interpreter is the
optional per-fleet fallback. `acq_py/runtime.py` resolves the runtime to use and
never downloads one; acquisition (download + checksum + provenance) belongs to
the installer slice.

**Patch cadence (PROPOSAL — pending developer decision, not yet settled):**
re-verify and re-pin the managed runtime and dependency wheelhouse on the
existing quarterly review cadence (the same cadence that governs re-verifying
backend patterns and Tier-3 transcripts), with an immediate out-of-band patch
for any critical/high CVE affecting the bundled CPython or wheelhouse. The
developer is the decider here; this proposal is flagged rather than adopted.

## Built-in kit bundle

The built-in kits (the four support kits and the `opencode` agent kit) ship as
package data in `src/acq_py/kitbundle/`, a byte-exact copy of the Patterns
control plane at `CONTROL_PLANE_REF` (`src/acq_py/kits.py`, equal to
`PATTERNS_KIT_REF` in `acq.backends/common.sh`). `kitbundle/MANIFEST.json`
records the ref and each file's git blob id and size; `upstream_mode` is
informational. `src/acq_py/kitspec.py` parses and selects kits from it, so acq
never fetches a built-in kit during ordinary operation (ADR-0042m).

On msb, acq applies each kit itself (`src/acq_py/kit_msb.py`). On sbx,
`src/acq_py/kit_sbx.py` translates each kit into an sbx-v2 kit directory under
`<state>/sbx-kits/` exactly as Bash `kit_translate_to_sbx` does, adds the host
git identity kit and a startup-barrier kit, and passes them all to
`sbx create --kit`; create then waits for the barrier. Until it is seen the
state record says `kits_unconfirmed`, and every verb that attaches refuses the
sandbox, so a create that times out or is interrupted and cannot remove the
sandbox never leaves it attachable. Translated kits are named by content and
shared between creates; unused ones are pruned after a week. `acq kit apply` and
`acq kit update` on sbx use `sbx kit add`, which sbx 0.38 and later refuse for
kits with startup commands, so those report that the sandbox must be recreated.
`py-acq/tests/test_kit_sbx.py` compares the translator's output with Bash's,
file by file.

### Kits outside the bundle

A kit the bundle does not hold (an opt-in catalog kit from config `extra_kits`,
a remote `ACQ_EXTRA_KITS` or `--kit` ref, a provider kit from a registered kit
source) is fetched by `src/acq_py/kit_fetch.py`, a port of Bash
`kit_translate_fetch` with the same refusals and some stricter ones:

* Only `git+https://HOST/PATH#ref=SHA&dir=DIR` is fetched, and `SHA` must be a
  full 40-hex commit id. A branch or tag name is refused with
  `kit_ref_not_pinned` (Bash fetches it unverified). So are URL userinfo
  (`credential-bearing kit URLs are not allowed`), plain `http`, a query
  string or percent escapes, and a `dir=` that is absolute, contains `..` or
  uses a character outside `[A-Za-z0-9._/-]`.
* A local kit directory (Bash reads it in place) is copied into the same
  private cache first, and every check runs on the copy, so a change to the
  directory during the checks cannot reach the sandbox. The copy follows no
  link: a link in the kit is copied as a link and must resolve inside the copy
  (on Windows a link or junction in a local kit is refused outright), and
  anything but files, directories and links is refused, as is a tree of more
  than 10000 entries, 256 MiB or 64 levels of directories. On Windows each
  copied file's real path (`GetFinalPathNameByHandleW`) must lie under the kit.
  A directory that does not exist is `validation_failed`. The copy is named by
  its content.
* The commit is fetched into a bare repository and must be exactly the pinned
  one; the kit is checked out from that commit's tree with a private index, and
  no symlink in it may resolve outside the kit. Only a neutral `hybrid/v1` kit
  with a plain `name:` is applied (Bash also passes sbx-native kits through).
* git is resolved to an absolute path, runs with `GIT_DIR` and the other
  redirecting variables removed, without prompts, with stdin closed and under
  `ACQ_KIT_FETCH_TIMEOUT` (default 120 s). The first attempt reads no git
  config files and may use only https (`GIT_ALLOW_PROTOCOL`, never wider than
  one the user set); only if it fails is it retried with the user's config (for
  a credential helper or a URL rewrite, which may lead to another transport such
  as an ssh mirror; the commit is still checked against the pin). Neither
  attempt runs a git hook from the user's config. git's own messages are never
  shown.
* Any failure, including a network failure, refuses the create (or the heal)
  before anything is created, on both backends; sbx is only ever given acq's
  translation of the kit, never the ref.
* A verified commit is kept under the backend's kit cache (`ACQ_MSB_KIT_CACHE`,
  `ACQ_SBX_KIT_CACHE`; by default `$XDG_CACHE_HOME/acq/kits` and
  `.../acq/sbx-kits`) in a private `py-fetch/` directory, so later commands,
  such as the heal on `start`, reuse it offline. Bash fetches again in every
  process.

A fetched kit's egress allowlist on msb is read from its own spec, as Bash
reads every kit's; the built-in kits keep the vetted table in `kits.py`. A
fetched provider kit's facts face the same pin check as the bundled one's, so a
kit cannot choose where a stored key is sent. Tests never use the network: the
test configuration lets git use only its `file` transport, and
`py-acq/tests/test_kit_fetch.py` fetches from a local bare repository.

Provider-role kits (`usai-provider`) are handled by `src/acq_py/provider_input.py`.
Before any create (and before `create --recreate` removes the old guest) acq
checks each selected provider's facts against its pin and checks that a key is
stored: on a terminal it asks and stores one, otherwise it fails closed with
`secret_missing`. This is stricter than Bash: a key exported in the host
environment is not accepted (store it with `acq secret set -g usai`), and a
provider with no pin is refused even if a host was recorded earlier (see
`docs/KNOWN_FAILURE_MODES.md`, section 56). The provider-input generation is
staged before the create, mounted read-only and named by `ACQ_PROVIDER_INPUT_ROOT`
for OpenCode's renderer, and published as `current` only once the create
succeeded. On msb it is mounted with `--volume HOST:GUEST:ro` where msb can
enforce a read-only mount. On sbx it is an extra workspace `PATH:ro` placed after
the primary workspace (sbx mounts it at the same path in the guest), as Bash
does; a generation for a create that failed is discarded only once `sbx ls`
confirms no sandbox can be mounting it. Neither backend stages or mounts it on
Windows yet (sections 54 and 55); the facts are still recorded for the key check.
Where a generation is published on Windows, `current` is written as the pointer
file the Bash acq writes there, not a symlink (section 61). Before
`run` attaches, each recorded provider's key is probed from inside the guest
(`provider_auth_failed`, `provider_unreachable`). Tests that create msb
sandboxes use the `provider_key` pytest marker, which stores a throwaway usai
key; the stubs answer the probe from `ACQ_MSB_STUB_PROBE` / `ACQ_SBX_STUB_PROBE`.

To bump the pin, change both refs, then regenerate the bundle and commit it
with the bump:

```sh
scripts/refresh-kitbundle                    # reads the pinned tree through `gh api`
scripts/refresh-kitbundle --checkout DIR     # or from a Patterns clone that has the pin
python -m pytest py-acq/tests/test_kitspec.py -q
```

The tests check the bundled files against the manifest and the refs against
each other. The networked pre-commit job (`.github/workflows/pre-commit.yml`)
also runs `scripts/refresh-kitbundle --check` against its checkout of Patterns
at the pin, which fails when any manifest blob id differs from
`git ls-tree -r <ref>`.

## Timeouts

The waits in the table below are bounded. Other backend calls run without a
time limit, among them `create`, `stop` and `rm` on both backends and `msb
start` (an image pull or a guest boot can legitimately take long), as well as
copies, port and inspect queries and sbx settings changes. Each bound is a
number of seconds read from the environment when it is needed.
A value that is not a finite number, or is negative, is ignored with a warning
on stderr, and the default is used. Where the table says "more than 0", a value
of 0 is also ignored, because it would fail the call at once instead of meaning
"no limit".

| Env var | Default | Bounds |
|---------|---------|--------|
| `ACQ_LIST_TIMEOUT` | `60` (more than 0) | One backend sandbox listing (`msb list`, `sbx ls`), behind `acq ls` and every existence or running check in create, run, start, rm and the secret re-feeds. A listing that does not answer in time fails the command with `timeout`. On Windows the listing runs in a Job object, and a timeout ends it and every process it started, such as an msb server it started itself (as every bounded backend call does there). |
| `ACQ_ROTATE_TIMEOUT` | `120` (more than 0) | Each backend call `acq usai-rotate-api-key` makes while it holds the usai provider lock. |
| `ACQ_SBX_KIT_ADD_TIMEOUT` | `240` (more than 0) | One `sbx kit add` (the kit heal before an attach, `kit apply`, `kit update`), which runs with the sandbox's lifecycle lock held. A heal that times out warns and the attach goes on. The default stays below `ACQ_SANDBOX_LOCK_TIMEOUT`, so a command waiting for the lock outlasts one hung kit add; if you raise this one, raise that one above it. |
| `ACQ_KIT_FETCH_TIMEOUT` | `120` (more than 0) | Each git step of fetching a pinned remote kit. |
| `ACQ_MSB_KIT_TIMEOUT` | `1800` | One in-guest kit-install or substrate step on msb. |
| `ACQ_MSB_READY_TIMEOUT`, `ACQ_SBX_READY_TIMEOUT` | `30` | The wait for a new sandbox to accept `exec`. |
| `ACQ_SBX_STARTUP_BARRIER_TIMEOUT` | `60` | The wait for an sbx sandbox's kit startup commands to finish. |
| `ACQ_SANDBOX_LOCK_TIMEOUT` | `300` | The wait for a sandbox's lifecycle lock, a provider-credential lock, or the secret-store lock that global secret changes and creates share. |
| `ACQ_MIGRATION_LOCK_TIMEOUT` | `5` | The wait for the state-migration lock and the config lock. |

A command that has waited about two seconds for any of these locks prints one
line on stderr, `acq: waiting for <the lock>, held by another acq command...`,
and keeps waiting. It never writes that line to stdout, so `--json` output is
unchanged. While a global secret change waits for the secret-store lock, new
creates and starts wait behind it, so a steady stream of them cannot keep it
out until it times out.

## Testing

Two runners consume the same `test/vectors/` corpus and must agree on the
sentinel golden set (ADR-0043m):

```text
python -m pytest py-acq/tests -q      # pytest runner + coverage manifest
scripts/run-vectors --acq "python -m acq_py"   # Bash runner (jq)
```

On Windows, a global `commit.gpgsign` (for example 1Password's `op-ssh-sign`)
makes `git commit` fail inside the tests' temporary repos. Neutralize the
inherited config for a hermetic run:

```sh
# GIT_CONFIG_GLOBAL="" does not help: git falls back to ~/.gitconfig.
GIT_CONFIG_GLOBAL=NUL GIT_CONFIG_NOSYSTEM=1 python -m pytest py-acq/tests -q
```

With the override, the suite is expected to pass on Windows; the Windows CI job
(`.github/workflows/windows.yml`) runs it on every relevant pull request. The
`install.sh` tests that need a supported platform are skipped there, because
`install.sh` refuses Windows hosts and `install.ps1` is the Windows installer.
Without the override, roughly 30 failures in `test_qualification_host.py` and
`test_qualification_gate.py` come from that signing hook, not the code under
test.

See `../test/vectors/README.md` for the vector schema, assertion modes, and
normalisation transforms. Contract evidence is subprocess-only (ADR-0039m);
the sentinel set covers every assertion mode (`exact`/`contains`/`json`) and
every normalisation transform (`abspath`/`tmpdir`/`crlf`/`timing`/`order`/`json`).

### Quality gates

`.github/workflows/python-quality.yml` runs ruff, mypy and bandit on `src/`
and fails when pytest's in-process branch coverage drops below the
`fail_under` floor in `pyproject.toml`. The tools are CI-only, pinned with
hashes in `requirements-quality.txt` (policy: ADR-0049m). To run the gates
locally, use a throwaway virtual environment and run the commands from
`py-acq/`:

```sh
python -m pip install --require-hashes --no-deps --only-binary :all: -r requirements-quality.txt
python -m ruff check src
python -m mypy
python -m bandit -c pyproject.toml -r src
python -m pytest -q --cov --cov-report=term
```

The gates started at zero findings, so there is no baseline. A finding that
is a false positive gets a targeted suppression with its reason on the same
line, such as `# nosec B105 # an error code`. Do not widen the skip lists in
`pyproject.toml` to clear one.

### Windows

`.github/workflows/windows.yml` runs on a Windows runner when a pull request
touches Windows-relevant paths. It runs pytest, smoke tests of `acq.cmd` and
`acq.ps1` for both `ACQ_IMPL` paths, `install.ps1 -DryRun` under PowerShell 7
and Windows PowerShell 5.1, the release job's managed-runtime staging and
smoke check, and a Git Bash run of `55-version.bats` and
`06-windows-install.bats`.
