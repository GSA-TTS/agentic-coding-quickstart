"""acq v1 Python skeleton (foundation slice).

This package is the Python replacement for the Bash ``acq`` wrapper. The
foundation slice provides the CLI entrypoint, the structured-output envelope,
managed-runtime resolution, and the version/identity data. The backend-detection
slice adds the read side of the adapter seam: backend discovery, ``backend
list``, and the fail-closed version floor. The mutating backend verbs and the
remaining command surface land in later slices.

See ``py-acq/README.md`` for the coexistence plan, the runtime supplier, and the
patch-cadence proposal.
"""

__version__ = "0.1.0"
