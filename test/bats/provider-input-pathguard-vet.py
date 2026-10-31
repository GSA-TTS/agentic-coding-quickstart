#!/usr/bin/env python3
# Offline checks for the Windows provider-input path guard's component vetting.
# The module is Windows-only at runtime (kernel32), but the decision "is this
# opened component a direct child of the vetted parent" is pure once the handle
# attributes and resolved names are supplied. This drives the real _walk with a
# fake volume: a literal path maps to the resolved name the kernel would report
# for it, so 8.3 aliases, redirects, and reparse points can be modelled on any
# host. It proves the comparison logic only, not that Windows reports those
# names (see ADR-0038).

import ntpath
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve() / "acq.backends"))
import provider_input_pathguard as guard  # noqa: E402

DIR = guard.FILE_ATTRIBUTE_DIRECTORY
LINK = guard.FILE_ATTRIBUTE_REPARSE_POINT
FILE = 0x0020


def _key(path):
    return ntpath.normcase(ntpath.normpath(path))


def walk(volume, path, create=False):
    """Run guard._walk over VOLUME: {literal: (resolved name, attributes)}."""
    table = {_key(literal): value for literal, value in volume.items()}

    def open_component(literal, _create):
        if _key(literal) not in table:
            raise guard.UnsafePath("missing %r" % (literal,))
        return _key(literal)

    saved = (
        guard._open_directory,
        guard._open_component,
        guard._attributes,
        guard._final_path,
        guard._close,
    )
    guard._open_directory = lambda literal: _key(literal)
    guard._open_component = open_component
    guard._attributes = lambda handle: table[handle][1]
    guard._final_path = lambda handle: table[handle][0]
    guard._close = lambda handle: None
    try:
        guard._walk(path, create)
    finally:
        (
            guard._open_directory,
            guard._open_component,
            guard._attributes,
            guard._final_path,
            guard._close,
        ) = saved


failures = []


def check(name, volume, path, accepted):
    try:
        walk(volume, path)
        result = True
    except guard.UnsafePath:
        result = False
    status = "ok" if result == accepted else "FAIL"
    print("%s %s (%s)" % (status, name, "accepted" if result else "rejected"))
    if result != accepted:
        failures.append(name)


ROOT = ("C:\\", DIR)
volume = {
    "C:\\": ROOT,
    "C:\\Program Files": ("C:\\Program Files", DIR),
    "C:\\PROGRA~1": ("C:\\Program Files", DIR),
    "C:\\PROGRA~1\\acq": ("C:\\Program Files\\acq", DIR),
    "C:\\Users": ("C:\\Users", DIR),
    "C:\\Users\\RUNNER~1": ("C:\\Users\\runneradmin", DIR),
    "C:\\Users\\RUNNER~1\\tree": ("C:\\Users\\runneradmin\\tree", DIR),
    "C:\\Users\\runneradmin": ("C:\\Users\\runneradmin", DIR),
    "C:\\Users\\Runneradmin\\tree": ("C:\\Users\\runneradmin\\tree", DIR),
    "C:\\Users\\runneradmin\\tree": ("C:\\Users\\runneradmin\\tree", DIR),
}

# Legitimate paths.
check("long name", volume, "C:\\Users\\runneradmin\\tree", True)
check("8.3 first component", volume, "C:\\PROGRA~1\\acq", True)
check("8.3 mid-path component", volume, "C:\\Users\\RUNNER~1\\tree", True)
check("case-only difference", volume, "C:\\Users\\Runneradmin\\tree", True)
check("forward slashes", volume, "C:/Users/runneradmin/tree", True)
check("drive root only", volume, "C:\\", True)

# Case may differ between the parent's resolved name and the child's resolved head.
cased = dict(volume)
cased["C:\\Users\\runneradmin"] = ("C:\\USERS\\RunnerAdmin", DIR)
cased["C:\\Users\\runneradmin\\tree"] = ("C:\\users\\runneradmin\\tree", DIR)
check("case differs between parent and child resolved names", cased, "C:\\Users\\runneradmin\\tree", True)

# Redirects: same shape as a legitimate path, resolved somewhere else.
redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Elsewhere\\target", DIR)
check("child resolves to a different parent", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("D:\\Users\\evil", DIR)
check("child resolves to another volume", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Users\\a\\b", DIR)
check("child resolves deeper than one level", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\", DIR)
check("child resolves to the parent's ancestor", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\evil"] = ("C:\\", DIR)
check("child of the root resolves to the root", redirects, "C:\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Users", DIR)
check("child resolves to the parent itself", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Users\\a\\..\\evil", DIR)
check("resolved name carries a .. escape", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Users\\.", DIR)
check("resolved name is the parent via a dot", redirects, "C:\\Users\\evil", False)

redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Users\\evil:stream", DIR)
check("alternate data stream name", redirects, "C:\\Users\\evil", False)

# A redirect hidden behind an 8.3-looking literal must still be caught.
redirects = dict(volume)
redirects["C:\\Users\\EVIL~1"] = ("C:\\Elsewhere\\evil", DIR)
check("8.3 literal resolving elsewhere", redirects, "C:\\Users\\EVIL~1", False)

# A redirect partway down: later components resolve under the redirect target,
# which is not under the vetted parent, so the first redirected step fails.
redirects = dict(volume)
redirects["C:\\Users\\evil"] = ("C:\\Elsewhere\\target", DIR)
redirects["C:\\Users\\evil\\child"] = ("C:\\Elsewhere\\target\\child", DIR)
check("descendant of a redirected component", redirects, "C:\\Users\\evil\\child", False)

# Attribute checks come first and are unchanged.
linked = dict(volume)
linked["C:\\Users\\runneradmin\\tree"] = ("C:\\Users\\runneradmin\\tree", DIR | LINK)
check("reparse point with a matching name", linked, "C:\\Users\\runneradmin\\tree", False)

linked = dict(volume)
linked["C:\\Users\\RUNNER~1"] = ("C:\\Users\\runneradmin", DIR | LINK)
check("reparse point behind an 8.3 alias", linked, "C:\\Users\\RUNNER~1", False)

linked = dict(volume)
linked["C:\\Users\\evil"] = ("C:\\Elsewhere\\target", DIR | LINK)
check("reparse point that also redirects", linked, "C:\\Users\\evil", False)

plain = dict(volume)
plain["C:\\Users\\runneradmin\\tree"] = ("C:\\Users\\runneradmin\\tree", FILE)
check("not a directory", plain, "C:\\Users\\runneradmin\\tree", False)

check("missing component", volume, "C:\\Users\\nobody", False)

# UNC shares keep their \\server\share anchor through normalization.
unc = {
    "\\\\srv\\share": ("\\\\srv\\share\\", DIR),
    "\\\\srv\\share\\SHARED~1": ("\\\\srv\\share\\Shared Data", DIR),
    "\\\\srv\\share\\Shared Data": ("\\\\srv\\share\\Shared Data", DIR),
    "\\\\srv\\share\\evil": ("\\\\other\\share\\evil", DIR),
}
check("UNC share with an 8.3 component", unc, "\\\\srv\\share\\SHARED~1", True)
unc_bare = dict(unc)
unc_bare["\\\\srv\\share"] = ("\\\\srv\\share", DIR)
unc_bare["\\\\srv\\share\\x"] = ("\\\\srv\\share\\x", DIR)
check("UNC share root reported without a trailing slash", unc_bare, "\\\\srv\\share\\x", True)
check("colon in an input component", volume, "C:\\Users\\C:foo", False)
check("drive-relative input component", volume, "C:\\Users\\D:foo", False)
check("UNC child resolving to another server", unc, "\\\\srv\\share\\evil", False)


# _final_path prefix stripping, with the kernel call stubbed out.
class _Kernel:
    def __init__(self, value):
        self.value = value

    def GetFinalPathNameByHandleW(self, _handle, buffer, _size, _flags):
        buffer.value = self.value
        return len(self.value)


for raw, want in (
    ("\\\\?\\C:\\Users\\x", "C:\\Users\\x"),
    ("\\\\?\\UNC\\srv\\share\\x", "\\\\srv\\share\\x"),
    ("\\\\?\\unc\\srv\\share\\x", "\\\\srv\\share\\x"),
    ("C:\\plain", "C:\\plain"),
):
    guard._KERNEL32 = _Kernel(raw)
    got = guard._final_path(1)
    status = "ok" if got == want else "FAIL"
    print("%s final path prefix %r -> %r" % (status, raw, got))
    if got != want:
        failures.append("prefix " + raw)

sys.exit(1 if failures else 0)
