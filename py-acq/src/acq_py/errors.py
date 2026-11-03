"""Exit-code and error-code vocabulary (ADR-0038m).

Exit codes:
    0 — completed operation / successful query answer
    1 — operational, validation, support, or incomplete failure
    2 — usage error

The foundation slice needs only the usage/failure minimum plus the
``unsupported_capability`` code that later backend adapters share. The full
~14-code backend error vocabulary (ADR-0040m) lands with the adapters.
"""

EXIT_SUCCESS = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2

USAGE = "usage"
INTERNAL = "internal"
UNSUPPORTED = "unsupported_capability"
