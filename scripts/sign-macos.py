#!/usr/bin/env python3
"""Developer ID sign every Mach-O in the relocated release; fail on any unsigned code."""
import argparse
from pathlib import Path
import subprocess

MAGIC = {bytes.fromhex(s) for s in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def machos(root):
    result = []
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) in MAGIC:
                result.append(path)
    return sorted(result)


def sign(root, identity, team):
    if not identity.startswith('Developer ID Application:'):
        raise ValueError('A Developer ID Application identity is required')
    files = machos(root)
    if not files:
        raise ValueError('Release contains no Mach-O code')
    entitlements = Path(__file__).with_name('beam-macos.entitlements')
    # All bundled native libraries/NIFs share our team, so library validation stays enabled.
    for path in files:
        command = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp']
        if path.name == 'beam.smp':
            command += ['--entitlements', str(entitlements)]
        subprocess.run(command + [str(path)], check=True)
    for path in files:
        subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
        details = subprocess.run(['codesign', '-dv', '--verbose=4', str(path)], check=True, capture_output=True, text=True).stderr
        if f'TeamIdentifier={team}' not in details or 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
            raise RuntimeError(f'Invalid Developer ID or hardened runtime signature: {path}')
    print(f'Developer ID signed and verified {len(files)} Mach-O files')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release', type=Path)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--team', required=True)
    args = parser.parse_args()
    sign(args.release.resolve(strict=True), args.identity, args.team)
