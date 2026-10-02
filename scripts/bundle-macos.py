#!/usr/bin/env python3
"""Bundle non-system Mach-O dependencies and ad-hoc sign the relocated ARM release.

No Developer ID/notarization is implied. Fail closed on unresolved library paths.
Run on macOS after mix release, before packaging.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
bundled = root / "native-libs"
bundled.mkdir(exist_ok=True)
magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in magic


def run(*args):
    return subprocess.check_output(args, text=True)


def rpaths(source):
    lines = run("otool", "-l", str(source)).splitlines()
    result = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            result.append(lines[index + 2].strip().split("path ", 1)[1].rsplit(" (offset ", 1)[0])
    return result


def resolve(dependency, source):
    if dependency.startswith("@loader_path/"):
        return (source.parent / dependency[len("@loader_path/"):]).resolve()
    if dependency.startswith("@rpath/"):
        for entry in rpaths(source):
            base = entry.replace("@loader_path", str(source.parent))
            candidate = Path(base) / dependency[len("@rpath/"):]
            if candidate.is_file():
                return candidate.resolve()
        raise RuntimeError("Unresolved dependency: " + dependency + " in " + str(source))
    if not dependency.startswith("/"):
        raise RuntimeError("Unresolved dependency: " + dependency + " in " + str(source))
    return Path(dependency).resolve()


queue = [(path, path) for path in root.rglob("*") if macho(path)]
sources = {}
processed = []
while queue:
    target, source = queue.pop()
    dependencies = run("otool", "-L", str(source)).splitlines()[1:]
    # A dylib's first entry is its own install ID, not a dependency.
    identifiers = run("otool", "-D", str(source)).splitlines()[1:]
    own_id = identifiers[0].strip() if identifiers else None
    for line in dependencies:
        dependency = line.strip().rsplit(" (compatibility version", 1)[0]
        if dependency == own_id:
            continue
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        original = resolve(dependency, source)
        if root in original.parents:
            destination = original
        else:
            if original not in sources:
                digest = hashlib.sha256(str(original).encode()).hexdigest()[:12]
                destination = bundled / (digest + "-" + original.name)
                shutil.copy2(original, destination)
                destination.chmod(0o755)
                sources[original] = destination
                queue.append((destination, original))
            destination = sources[original]
        relative = os.path.relpath(destination, target.parent)
        subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + relative, str(target)], check=True)
    if own_id:
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + target.name, str(target)], check=True)
    processed.append(target)

for target in processed:
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)
print("Bundled and ad-hoc signed", len(processed), "Mach-O files")
