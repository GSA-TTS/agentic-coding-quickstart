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
INTERNAL = "internal"
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
