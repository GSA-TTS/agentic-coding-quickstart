"""Module entrypoint so ``python -m acq_py`` runs the CLI."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
