"""Generate the shared offline recovery artifact for wheel and sdist builds."""
import runpy
from pathlib import Path

from setuptools import setup
from setuptools.command.build_py import build_py
from setuptools.command.sdist import sdist


def generate_recovery(target):
    project = Path(__file__).resolve().parent
    generator = runpy.run_path(str(project / "recovery_build.py"))["generate_recovery"]
    generator(project, target)


class RecoveryBuild(build_py):
    def run(self):
        super().run()
        generate_recovery(Path(self.build_lib) / 'acq_py/uninstall.command')


class RecoverySdist(sdist):
    def make_release_tree(self, base_dir, files):
        super().make_release_tree(base_dir, files)
        generate_recovery(Path(base_dir) / 'src/acq_py/uninstall.command')


setup(cmdclass={"build_py": RecoveryBuild, "sdist": RecoverySdist})
