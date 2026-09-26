#!/usr/bin/env python3
"""No network, Git mutation, credentials or native build needed."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name('export-public-source.py')
spec = importlib.util.spec_from_file_location('public_source', SCRIPT)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'source'
        self.root.mkdir()

    def write(self, name, data, executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
        path.chmod(0o755 if executable else 0o644)
        return path

    def inventory(self, names):
        self.write(exporter.INVENTORY, '\n'.join(sorted(names)) + '\n')

    def test_inventory_rejects_traversal_private_paths_and_duplicates(self):
        for name in ('../secret', '/tmp/key', '.', 'docs/private.md',
                     '.git/config', 'apps/.build/cache', 'services/push/.env',
                     'apps/token.p8', 'apps/reference.ipa', 'apps\\outside',
                     'research/CLAUDE_AGENT_SDK_IMPLEMENTATION_PLAN.md',
                     'research/CLAUDE_IMPLEMENTATION_STATUS.md',
                     'scripts/claude-sdk-smoke/explore.mjs'):
            self.inventory([name])
            with self.assertRaises(ValueError, msg=name):
                exporter.read_inventory(self.root)
        self.inventory(['README.md', 'README.md'])
        with self.assertRaises(ValueError):
            exporter.read_inventory(self.root)

    def test_export_copies_only_selected_bytes_and_executable_bit(self):
        self.write('README.md', 'Public text')
        self.write('scripts/run.sh', '#!/bin/sh\nexit 0\n', executable=True)
        self.write('.git/config', 'private history')
        self.write('apps/notes.txt', 'unlisted personal note')
        records, findings = exporter.audit(self.root, ['README.md', 'scripts/run.sh'])
        self.assertEqual(findings, [])
        destination = self.base / 'export'
        exporter.export_tree(self.root, destination, records)
        self.assertEqual(exporter.verify_tree(destination, records), [])
        self.assertFalse((destination / '.git').exists())
        self.assertFalse((destination / 'apps/notes.txt').exists())
        self.assertEqual((destination / 'scripts/run.sh').stat().st_mode & 0o777, 0o755)
        with self.assertRaises(ValueError):
            exporter.export_tree(self.root, destination, records)

    def test_symlink_file_and_parent_are_rejected(self):
        outside = self.base / 'private.txt'
        outside.write_text('private')
        (self.root / 'link.txt').symlink_to(outside)
        (self.root / 'nested').symlink_to(self.base, target_is_directory=True)
        _, findings = exporter.audit(self.root, ['link.txt', 'nested/private.txt'])
        self.assertEqual([item['kind'] for item in findings], ['symlink', 'symlink'])

    def test_nonallowlisted_binary_and_missing_files_are_rejected(self):
        self.write('apps/reference.png', b'\x89PNG\x00private screenshot')
        _, findings = exporter.audit(self.root, ['apps/reference.png', 'missing.rs'])
        self.assertEqual([item['kind'] for item in findings], ['unreviewed-binary', 'missing-file'])

    def test_reports_never_include_detected_values(self):
        fake_token = 'ghp_' + 'x' * 36
        fake_path = '/Users/' + 'real-person' + '/private'
        text = fake_token + '\n' + fake_path + '\n/Users/example/test\n'
        findings = exporter.text_findings('file.txt', text)
        self.assertEqual({item['kind'] for item in findings},
                         {'github-token', 'non-synthetic-account-path'})
        report = json.dumps(findings)
        self.assertNotIn(fake_token, report)
        self.assertNotIn('real-person', report)
        self.assertEqual({item['line'] for item in findings}, {1, 2})

    def test_links_and_compile_time_inputs_must_survive_export(self):
        self.write('README.md', '[schema](packages/schema.json) [private](docs/notes.md) '
                   '[web](https://example.org/) [same](#heading)\n```\n[x](ignored)\n```')
        self.write('packages/schema.json', '{}')
        self.write('crates/lib.rs', 'let x = include_str!("../missing.json");')
        _, findings = exporter.audit(self.root, ['README.md', 'packages/schema.json', 'crates/lib.rs'])
        self.assertEqual({item['target'] for item in findings}, {'docs/notes.md', 'missing.json'})

    def test_source_change_after_audit_is_detected(self):
        path = self.write('README.md', 'before')
        records, _ = exporter.audit(self.root, ['README.md'])
        path.write_text('after')
        with self.assertRaisesRegex(ValueError, 'changed during export'):
            exporter.export_tree(self.root, self.base / 'export', records)

    def test_verification_detects_extra_history_modified_content_and_modes(self):
        self.write('README.md', 'public')
        self.write('scripts/run.sh', 'exit 0\n', executable=True)
        records, _ = exporter.audit(self.root, ['README.md', 'scripts/run.sh'])
        destination = self.base / 'export'
        exporter.export_tree(self.root, destination, records)
        (destination / 'README.md').write_text('changed')
        (destination / 'scripts/run.sh').chmod(0o644)
        (destination / '.git').mkdir()
        (destination / '.git/config').write_text('private')
        kinds = {item['kind'] for item in exporter.verify_tree(destination, records)}
        self.assertEqual(kinds, {'export-content-mismatch', 'export-mode-mismatch',
                                 'forbidden-export-entry', 'unexpected-export-file'})

    def test_failed_audit_leaves_no_export(self):
        self.inventory(['missing.rs'])
        destination = self.base / 'export'
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root),
                                 '--output', str(destination), '--report', str(self.base / 'report')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue((self.base / 'report/source-audit.json').is_file())

    def test_private_report_cannot_be_written_into_export(self):
        self.inventory(['README.md'])
        self.write('README.md', 'public')
        destination = self.base / 'export'
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root),
                                 '--output', str(destination), '--report', str(destination / 'report')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(destination.exists())

    def test_nested_export_does_not_inherit_private_checkout_metadata(self):
        result = subprocess.CompletedProcess([], 0, stdout=str(self.base), stderr='')
        with patch.object(exporter.subprocess, 'run', return_value=result) as run:
            self.assertEqual(exporter.git_metadata(self.root, []),
                             {'sourceCommit': None, 'sourceStatus': None, 'excludedTrackedFiles': []})
        run.assert_called_once()


if __name__ == '__main__':
    unittest.main()
