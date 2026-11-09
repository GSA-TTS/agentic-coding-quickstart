"""Exit-code and error-code vocabulary (ADR-0038m).

Exit codes:
    0 — completed operation / successful query answer
    1 — operational, validation, support, or incomplete failure
    2 — usage error

The foundation slice needs only the usage/failure minimum plus the
``unsupported_capability`` code that backend adapters share. The backend error
vocabulary below (ADR-0040m) grows with the adapter seam: the read side lands the
version-floor codes here; the remaining codes land with the mutating verbs.
"""

EXIT_SUCCESS = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2

USAGE = "usage"

# The generic operational-failure token from the ADR-0038m exit-1 ``usage``/
# ``failure`` minimum. A backend command (e.g. ``msb create``) that returns
# nonzero is an operational failure no ADR-0040m code covers — it is not a
# version refusal, a sandbox-missing/exists condition, a validation refusal, or a
# timeout — so ``failure`` is the correct, stable code.
FAILURE = "failure"

UNSUPPORTED = "unsupported_capability"

# Backend error vocabulary (ADR-0040m), read side.
BACKEND_NOT_FOUND = "backend_not_found"
BACKEND_VERSION_UNSUPPORTED = "backend_version_unsupported"
BACKEND_VERSION_UNKNOWN = "backend_version_unknown"

# Backend error vocabulary (ADR-0040m), lifecycle side. These land with the
# mutating verbs (create/run/stop/rm/ls): a missing or already-present sandbox,
# a host-side validation refusal, and the exec-ready timeout.
SANDBOX_NOT_FOUND = "sandbox_not_found"
SANDBOX_EXISTS = "sandbox_exists"
VALIDATION_FAILED = "validation_failed"
TIMEOUT = "timeout"

# ADR-0041m state-schema refusal: a record carrying a newer or unknown schema (or
# unparseable content) is refused rather than misread. Forward migration of older
# (legacy v0) records is the state-migration slice's job.
STATE_SCHEMA_UNSUPPORTED = "state_schema_unsupported"

# Backend error vocabulary (ADR-0040m), secret verbs. ``secret_missing`` is the
# removal path's "no such secret" failure; ``secret_unreadable`` is the
# secret-list path's "store could not be read/parsed" failure. Neither is used for
# ``secret has``, which maps "absent" to a silent exit 1 (a predicate answer, not
# an error).
SECRET_MISSING = "secret_missing"  # nosec B105 # an error code
SECRET_UNREADABLE = "secret_unreadable"  # nosec B105 # an error code

# Kit slice (ADR-0038m §kit, ADR-0016 provenance, trusted-source policy).
# ``kit_ref_not_pinned``: ``kit-source add`` refuses a non-full (mutable) ref —
# a trusted source is fetched at an immutable full SHA, never a branch/tag.
# ``kit_source_not_found``: ``kit-source rm`` on a repository that is not
# registered as a trusted source.
# ``consent_required``: ``kit update`` refuses a non-interactive refresh that
# did not carry ``--yes`` (refresh is consented; automation never infers consent).
KIT_REF_NOT_PINNED = "kit_ref_not_pinned"
KIT_SOURCE_NOT_FOUND = "kit_source_not_found"
CONSENT_REQUIRED = "consent_required"

# State-migration slice (ADR-0041m). ``state_schema_unsupported`` (above) covers
# the fail-closed refusal of a newer/unparseable/min_reader record. These codes
# cover the migration machinery's own failures:
# ``migration_locked`` — the exclusive OS advisory migration lock could not be
#   acquired within the bounded wait (a second concurrent invocation fails
#   closed rather than racing the migration).
# ``migration_failed`` — a record could not be migrated atomically (write or
#   read-back verify failed); the old record is left intact and the path +
#   failed step are reported.
# ``security_exception`` — a sandbox whose host record requires the read-only
#   trusted-config mount (ADR-0035) reports the mount missing: trusted
#   operations fail closed and require consent-gated recreation.
MIGRATION_LOCKED = "migration_locked"
MIGRATION_FAILED = "migration_failed"
SECURITY_EXCEPTION = "security_exception"

# Provider-credential / rotation slice (ADR-0040m). ``provider_unreachable`` and
# ``provider_auth_failed`` are the stable rotation failure codes: rotation fails
# closed when the provider endpoint cannot be reached or rejects the new key, and
# the old key is never replaced until the new one is confirmed (ADR-0012).
PROVIDER_UNREACHABLE = "provider_unreachable"
PROVIDER_AUTH_FAILED = "provider_auth_failed"
