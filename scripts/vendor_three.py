#!/usr/bin/env python3
"""Vendors three.js for Lamp's animation renderer (`decisions/0027`).

    python3 -I scripts/vendor_three.py path/to/three-0.187.0.tgz

Takes npm's tarball for the pinned version, checks it against npm's
integrity hash, and writes the chosen builds and addons, with every file they
import, into Sources/LampBibleMacSupport/Resources/AnimationRuntime/three/ at
npm's own paths, with three's licence and MANIFEST.json: each file's SHA-256,
which the renderer serves only from and the notices script pins.

Nothing in the tarball is run, and it is read where it lies, never unpacked
to disk: only the chosen paths are written, under the output folder. It
refuses an import of anything outside the import map Lamp gives a page
(`three`, `three/webgpu`, `three/tsl`, `three/addons/...`), and any file of
`examples/jsm/libs/` (Draco, KTX2, EXR and the rest), which brings in
WebAssembly and workers Lamp does not serve.
"""

import base64
import hashlib
import json
import posixpath
import re
import shutil
import sys
import tarfile
from pathlib import Path

VERSION = "0.187.0"
# npm's integrity for the tarball: what the registry published, checked before anything is read.
INTEGRITY = "sha512-Qiu7R+Cmh8CstZsY1uJOSWnVlfo7ZtNLV7mF8Jltk3LB3AtDu9cRZlcnRKkAk8Y4z6KKw35z7Y7Urd7jWY8etA=="
ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources" / "LampBibleMacSupport" / "Resources" / "AnimationRuntime" / "three"

BUILDS = ["build/three.module.js", "build/three.core.js", "build/three.webgpu.js",
          "build/three.webgpu.nodes.js", "build/three.tsl.js"]
WHOLE = ["postprocessing", "shaders", "tsl", "geometries", "curves", "math", "objects", "environments",
         "lines", "lights", "helpers", "csm", "textures", "capabilities"]
# Whole, less the files that import from libs/.
WHOLE_LESS_LIBS = ["utils", "modifiers"]
FILES = [
    "loaders/GLTFLoader.js", "loaders/FontLoader.js", "loaders/HDRLoader.js", "loaders/RGBELoader.js",
    "loaders/SVGLoader.js", "loaders/OBJLoader.js", "loaders/MTLLoader.js", "loaders/STLLoader.js",
    "loaders/PLYLoader.js", "loaders/LUTCubeLoader.js", "loaders/LUT3dlLoader.js", "loaders/LUTImageLoader.js",
    "misc/GPUComputationRenderer.js", "renderers/CSS2DRenderer.js", "renderers/CSS3DRenderer.js",
]
# Never vendored, whatever imports them.
LEFT_OUT = ["examples/jsm/libs/", "examples/jsm/controls/", "examples/jsm/webxr/", "examples/jsm/inspector/",
            "examples/jsm/exporters/", "examples/jsm/physics/", "examples/jsm/generators/",
            "examples/jsm/loaders/TTFLoader.js"]
BARE = {"three": "build/three.module.js", "three/webgpu": "build/three.webgpu.js", "three/tsl": "build/three.tsl.js"}
ADDONS = "three/addons/"

# A module's own imports: statements at the start of a line, as three's sources
# and builds write them, never the word inside code a module generates (the
# WebGPU build writes WGSL with `import` in it); and dynamic imports of a
# literal.
STATIC = re.compile(r"""(?ms)^[ \t]*(?:import|export)\b[^;'"`]*?\bfrom\s*(['"])([^'"\n]+)\1""")
BARE_IMPORT = re.compile(r"""(?m)^[ \t]*import\s*(['"])([^'"\n]+)\1""")
DYNAMIC = re.compile(r"""\bimport\s*\(\s*(['"])([^'"\n]+)\1\s*\)""")


class VendorError(RuntimeError):
    pass


def specifiers(text):
    # Comments out first: a specifier quoted in one is not an import.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    found = [m.group(2) for pattern in (STATIC, BARE_IMPORT, DYNAMIC) for m in pattern.finditer(text)]
    return list(dict.fromkeys(found))


def resolve(importer, specifier):
    """The package path `specifier` names from `importer`, or an error."""
    if specifier in BARE:
        return BARE[specifier]
    if specifier.startswith(ADDONS):
        return "examples/jsm/" + specifier[len(ADDONS):]
    if specifier.startswith("./") or specifier.startswith("../"):
        path = posixpath.normpath(posixpath.join(posixpath.dirname(importer), specifier))
        if path.startswith("../") or path.startswith("/"):
            raise VendorError(f"{importer} imports {specifier}, outside the package")
        return path
    raise VendorError(f"{importer} imports {specifier!r}, which Lamp's import map does not give a page")


def main(tarball):
    data = Path(tarball).read_bytes()
    digest = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
    expected = INTEGRITY
    if digest != expected:
        raise VendorError(f"{tarball} is not npm's three@{VERSION}: {digest}")
    archive = tarfile.open(tarball, "r:gz")
    members = {}
    for member in archive.getmembers():
        if not member.isfile() or not member.name.startswith("package/"):
            continue
        members[member.name[len("package/"):]] = member

    def read(path):
        member = members.get(path)
        if member is None:
            raise VendorError(f"three@{VERSION} has no {path}")
        return archive.extractfile(member).read()

    def imports(path):
        return [resolve(path, s) for s in specifiers(read(path).decode("utf-8"))]

    def touches_libs(path, seen=None):
        seen = set() if seen is None else seen
        if path in seen:
            return False
        seen.add(path)
        if path.startswith("examples/jsm/libs/"):
            return True
        return any(touches_libs(p, seen) for p in imports(path) if p.endswith(".js"))

    roots = list(BUILDS)
    for folder in WHOLE:
        roots += sorted(p for p in members if p.startswith(f"examples/jsm/{folder}/") and p.endswith(".js"))
    for folder in WHOLE_LESS_LIBS:
        roots += sorted(p for p in members if p.startswith(f"examples/jsm/{folder}/") and p.endswith(".js")
                        and not touches_libs(p))
    roots += [f"examples/jsm/{p}" for p in FILES]

    chosen, queue = set(), list(roots)
    while queue:
        path = queue.pop()
        if path in chosen:
            continue
        if any(path.startswith(prefix) or path == prefix for prefix in LEFT_OUT):
            importers = [p for p in chosen if path in imports(p)]
            raise VendorError(f"{path} is left out, but {', '.join(importers) or 'a chosen file'} imports it")
        chosen.add(path)
        if path.endswith(".js"):
            queue += imports(path)

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    files = {}
    for path in sorted(chosen):
        body = read(path)
        target = OUTPUT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
        files[path] = hashlib.sha256(body).hexdigest()
    (OUTPUT / "LICENSE").write_bytes(read("LICENSE"))
    manifest = {"package": "three", "version": VERSION, "integrity": expected, "files": files}
    (OUTPUT / "MANIFEST.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    size = sum(len(read(p)) for p in chosen)
    print(f"three@{VERSION}: {len(files)} files, {size / 1_000_000:.1f} MB, into {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    try:
        main(sys.argv[1])
    except VendorError as error:
        sys.exit(f"vendor_three: {error}")
