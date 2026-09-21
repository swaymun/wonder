#!/usr/bin/env python3
"""Synthetic gate tests; no signing or VM execution is claimed."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gates", Path(__file__).with_name("verify-package-release-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class ReleaseGates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Wonder "quoted".app'
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents" / "binary").write_bytes(b"application")
        self.app_info = dict(CFBundleIdentifier="com.saimun.wonder", CFBundleVersion="2")
        (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(self.app_info))
        self.pkg = self.root / 'Wonder "quoted".pkg'
        self.pkg.write_bytes(b"installer")
        self.evidence = self.root / "evidence.json"
        self.report = self.root / "report.json"
        self.data = dict(schemaVersion=1, status="passed", pkgSha256=hashlib.sha256(b"installer").hexdigest(),
                         environment="fresh-vm", developerToolsUsed=False, manualDatabaseFixesUsed=False,
                         checks=dict(install="passed", pairing="passed", reconnect="passed"))
        self.team = "TEAM123"
        self.ad_hoc = False
        self.payload_changed = False
        self.notarized = True
        self.package_identifier = "com.saimun.wonder"
        self.package_version = "2"

    def command(self, *args):
        if args[0] == "codesign":
            if args[1] == "--verify":
                return True, ""
            return True, "Signature=adhoc" if self.ad_hoc else "Authority=Developer ID Application: Example (TEAM123)\nTeamIdentifier=TEAM123\n"
        if args[:2] == ("pkgutil", "--check-signature"):
            return True, f"Developer ID Installer: Example ({self.team})"
        if args[:2] == ("pkgutil", "--expand-full"):
            target = Path(args[3])
            target.mkdir()
            shutil.copytree(self.app, target / "Payload")
            (target / "PackageInfo").write_text(f'<pkg-info identifier="{self.package_identifier}" version="{self.package_version}" install-location="/Applications/Wonder.app"/>')
            if self.payload_changed:
                (target / "Payload" / "Contents" / "binary").write_bytes(b"other")
            return True, ""
        if args[0] == "spctl":
            return True, "source=Notarized Developer ID" if self.notarized else "source=Developer ID"
        raise AssertionError(args)

    def check(self, ready):
        self.evidence.write_text(json.dumps(self.data))
        with patch.dict(os.environ, {"WONDER_PACKAGE_GATE_PATH": str(self.report),
                                     "WONDER_FRESH_VM_GATE_FILE": str(self.evidence),
                                     "WONDER_REQUIRE_RELEASE_GATES": "1"}), \
             patch.object(sys, "argv", ["gate", str(self.app), str(self.pkg)]), \
             patch.object(gates, "run", self.command):
            self.assertEqual(gates.main(), 0 if ready else 2)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["releaseReady"], ready)
        self.assertEqual(report["appPath"], str(self.app))

    def test_all_gates_and_quoted_paths(self):
        self.check(True)

    def test_wrong_artifact_digest(self):
        self.data["pkgSha256"] = "0" * 64
        self.check(False)

    def test_unrelated_passed_status(self):
        self.data = {"nested": {"status": "passed"}}
        self.check(False)

    def test_incomplete_smoke(self):
        del self.data["checks"]["reconnect"]
        self.check(False)

    def test_manual_database_fix(self):
        self.data["manualDatabaseFixesUsed"] = True
        self.check(False)

    def test_ad_hoc(self):
        self.ad_hoc = True
        self.check(False)

    def test_mismatched_team(self):
        self.team = "OTHER123"
        self.check(False)

    def test_changed_package_payload(self):
        self.payload_changed = True
        self.check(False)

    def test_wrong_app_identifier(self):
        self.app_info["CFBundleIdentifier"] = "com.example.other"
        (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(self.app_info))
        self.check(False)

    def test_wrong_package_identifier(self):
        self.package_identifier = "com.example.other"
        self.check(False)

    def test_stale_package_version(self):
        self.package_version = "1"
        self.check(False)

    def test_not_notarized(self):
        self.notarized = False
        self.check(False)

    def test_malformed_evidence(self):
        self.evidence.write_text('{"status": "passed"')
        self.assertFalse(gates.fresh_vm_passed(str(self.evidence), self.data["pkgSha256"]))


if __name__ == "__main__":
    unittest.main()
