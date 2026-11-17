"""Generate the shared offline recovery artifact for wheel and sdist builds."""
from pathlib import Path
import shutil

from setuptools import setup
from setuptools.command.build_py import build_py
from setuptools.command.sdist import sdist


def generate_recovery(target):
    project = Path(__file__).resolve().parent
    root = project.parent
    bundled = project / "src/acq_py/uninstall.command"
    if not (root / "scripts/build-uninstaller").is_file():
        shutil.copy2(bundled, target)
        return
    builder = (root / "scripts/build-uninstaller").read_text()
    guard = builder.split("<<'PATH_GUARD'\n", 1)[1].split('\nPATH_GUARD', 1)[0]
    footer = builder.split("<<'FOOTER'\n", 1)[1].split('\nFOOTER', 1)[0]
    modules = ['uninstall-files.sh', 'uninstall-installation.sh', 'uninstall.sh']
    payload = '#!/bin/bash\n# Self-contained ACQ uninstaller; see ADR-0036.\nset -uo pipefail\n'
    payload += guard + '\n'
    payload += ''.join((root / 'acq.backends' / name).read_text() for name in modules)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((payload + footer + '\n').encode('utf-8'))


class RecoveryBuild(build_py):
    def run(self):
        super().run()
        generate_recovery(Path(self.build_lib) / 'acq_py/uninstall.command')


class RecoverySdist(sdist):
    def make_release_tree(self, base_dir, files):
        super().make_release_tree(base_dir, files)
        generate_recovery(Path(base_dir) / 'src/acq_py/uninstall.command')


setup(cmdclass={"build_py": RecoveryBuild, "sdist": RecoverySdist})
