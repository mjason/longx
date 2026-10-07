import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / 'scripts' / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


signing = module('sign-macos')
notary = module('check-notarization')


class SigningTest(unittest.TestCase):
    def test_release_repair_keeps_tag_and_native_runtime_checks(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/release.yml').read_text()
        ci = (root / '.github/workflows/ci.yml').read_text()
        self.assertIn("ref: ${{ inputs.release_tag || github.ref }}", workflow)
        self.assertIn('[[ "$RELEASE_TAG" == "v$version" ]]', workflow)
        self.assertEqual(workflow.count("tag_name: ${{ env.RELEASE_TAG }}"), 2)
        self.assertIn("unittest discover -v -s test -p '*macos*_test.py'", workflow)
        self.assertIn("unittest discover -s test -p '*_test.py'", ci)
        self.assertIn("install-macos.py --no-service --tarball", workflow)
        self.assertIn("Application.ensure_all_started(:longx)", workflow)
        self.assertIn("timeout-minutes: 10", workflow)

    def test_inventory_includes_extensionless_code_and_nifs_not_symlinks_or_scripts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            beam = root / 'beam.smp'
            beam.write_bytes(bytes.fromhex('cffaedfe') + b'code')
            nif = root / 'crypto.so'
            nif.write_bytes(bytes.fromhex('feedfacf') + b'code')
            (root / 'script').write_text('#!/bin/sh\n')
            (root / 'alias').symlink_to(beam)
            self.assertEqual(signing.machos(root), [beam, nif])

    def test_rejects_adhoc_and_empty_release(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                signing.sign(Path(temp), '-', 'TEAM')
            with self.assertRaises(ValueError):
                signing.sign(Path(temp), 'Developer ID Application: Test (TEAM)', 'TEAM')

    def test_notarization_rejects_invalid_and_missing_status(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'result.json'
            for status in ['Invalid', 'In Progress', None]:
                path.write_text(json.dumps({'status': status}))
                with self.assertRaises(RuntimeError):
                    notary.check(path)
            path.write_text(json.dumps({'status': 'Accepted', 'id': 'test'}))
            notary.check(path)
