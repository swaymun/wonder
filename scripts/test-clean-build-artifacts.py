import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).with_name('clean-build-artifacts.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def test_xcode_artifact_cleanup_removes_stale_receipt_and_keeps_checkouts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            derived = root / '.local/build/ios-diagnostics'
            packages = derived / 'SourcePackages'
            artifact = packages / 'artifacts/webrtc/WebRTC.xcframework/binary'
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b'cached binary')
            receipt = packages / 'workspace-state.json'
            receipt.write_text('{"object":{"artifacts":[{"path":"stale"}]}}')
            checkout = packages / 'checkouts/WebRTC/Package.swift'
            checkout.parent.mkdir(parents=True)
            checkout.write_text('pinned dependency source')
            (derived / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': '/app/Wonder.xcodeproj'}))
            cleanup.remove_candidates(cleanup.discover(root), root)
            self.assertFalse(artifact.exists())
            self.assertFalse(receipt.exists())
            self.assertEqual(checkout.read_text(), 'pinned dependency source')

    def test_swiftbuild_outputs_keep_sources_and_symbol_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            for relative in ('.local/build/native', 'apps/menubar/.build'):
                build = root / relative
                products = build / 'out/Products/Release'
                products.mkdir(parents=True)
                (build / 'manifest.pif').write_text('{}')
                (build / 'workspace-state.json').write_text('{}')
                (build / '.buildSystem_release').write_text('swiftbuild')
                (products / 'discard.o').write_bytes(b'output')
                symbol = products / 'Wonder.app.dSYM/Contents/Resources/DWARF/Wonder'
                symbol.parent.mkdir(parents=True)
                symbol.write_bytes(b'symbols')
                (build / 'checkouts').mkdir()
                (build / 'checkouts/source.swift').write_text('source')
            candidates = cleanup.discover(root)
            self.assertEqual(len(candidates), 2)
            cleanup.remove_candidates(candidates, root)
            self.assertEqual(cleanup.discover(root), [])
            self.assertEqual(len(list(root.rglob('*.dSYM/Contents/Resources/DWARF/Wonder'))), 2)
            self.assertEqual(len(list(root.rglob('source.swift'))), 2)

    def test_finds_nested_xcode_and_swift_scratch_caches(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            outer = root / '.local/simulator'
            inner = outer / 'another-run'
            for derived in (outer, inner):
                (derived / 'ModuleCache.noindex').mkdir(parents=True)
                (derived / 'SDKExplicitPrecompiledModules').mkdir()
                (derived / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': '/app/Wonder.xcodeproj'}))
            swift = root / '.local/swift-scratch'
            output = swift / 'arm64-apple-macosx/debug'
            output.mkdir(parents=True)
            (swift / 'build.db').touch()
            (swift / 'workspace-state.json').write_text('{}')
            self.assertEqual(set(cleanup.discover(root)), {
                outer / 'ModuleCache.noindex', inner / 'ModuleCache.noindex', output,
                outer / 'SDKExplicitPrecompiledModules', inner / 'SDKExplicitPrecompiledModules',
            })

    def test_keeps_evidence_source_and_symbols(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            derived = root / '.local/run/DerivedData'
            products = derived / 'Build/Products'
            symbol = products / 'Diagnostics-iphoneos/Wonder.app.dSYM/Contents/Resources/DWARF/Wonder'
            symbol.parent.mkdir(parents=True)
            symbol.write_bytes(b'unique crash symbols')
            (products / 'discard.o').write_bytes(b'compiler output')
            (derived / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(root / 'apps/ios/Wonder.xcodeproj')}))
            evidence = derived / 'Logs/Test/result.xcresult/data'
            evidence.parent.mkdir(parents=True)
            evidence.write_text('test evidence')
            source = root / 'source.swift'
            source.write_text('unsaved source')
            paths = cleanup.discover(root)
            self.assertEqual(paths, [products])
            cleanup.remove_candidates(paths, root)
            self.assertFalse(products.exists())
            self.assertEqual(evidence.read_text(), 'test evidence')
            self.assertEqual(source.read_text(), 'unsaved source')
            retained = list(derived.rglob('*.dSYM/Contents/Resources/DWARF/Wonder'))
            self.assertEqual(len(retained), 1)
            self.assertEqual(retained[0].read_bytes(), b'unique crash symbols')
            self.assertEqual(cleanup.discover(root), [])
            # A later build at the same path retains its own matching symbols.
            symbol.parent.mkdir(parents=True)
            symbol.write_bytes(b'new crash symbols')
            cleanup.remove_candidates(cleanup.discover(root), root)
            self.assertEqual(len(list(derived.rglob('*.dSYM/Contents/Resources/DWARF/Wonder'))), 2)

    def test_rejects_links_outside_root_and_tracked_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            protected = root / 'target/debug'
            protected.mkdir(parents=True)
            file = protected / 'important.txt'
            file.write_text('keep')
            subprocess.run(['git', '-C', str(root), 'add', str(file)], check=True)
            with self.assertRaises(ValueError):
                cleanup.remove_candidates([protected], root)
            self.assertEqual(file.read_text(), 'keep')
            (root / 'linked').symlink_to(protected, target_is_directory=True)
            with self.assertRaises(ValueError):
                cleanup.contained(root / 'linked/child', root)
            with self.assertRaises(ValueError):
                cleanup.contained(root.parent, root)


if __name__ == '__main__':
    unittest.main()
