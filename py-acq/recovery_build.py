"""Build offline recovery bytes without launching Bash or importing ACQ."""

from pathlib import Path


def generate_recovery(project: Path, target: Path) -> None:
    """Use current checkout modules, or the payload bundled in an sdist."""
    root = project.parent
    builder_path = root / "scripts/build-uninstaller"
    if not builder_path.is_file():
        payload = (project / "src/acq_py/uninstall.command").read_bytes()
    else:
        builder = builder_path.read_text(encoding="utf-8")
        guard = builder.split("<<'PATH_GUARD'\n", 1)[1].split("\nPATH_GUARD", 1)[0]
        footer = builder.split("<<'FOOTER'\n", 1)[1].split("\nFOOTER", 1)[0]
        modules = ("uninstall-files.sh", "msb-version-policy.sh", "uninstall-installation.sh", "uninstall.sh")
        text = "#!/bin/bash\n# Self-contained ACQ uninstaller; see ADR-0036.\nset -uo pipefail\n"
        text += guard + "\n"
        text += "".join((root / "acq.backends" / name).read_text(encoding="utf-8") for name in modules)
        payload = (text + footer + "\n").encode("utf-8")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
