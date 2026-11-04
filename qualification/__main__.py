"""Module entrypoint so ``python -m qualification`` runs the harness CLI."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
