#!/usr/bin/env python3
"""Validate distribution gates, with artifact-bound fresh-user evidence.

WONDER_FRESH_VM_GATE_FILE must contain JSON with schemaVersion: 1,
status: "passed", pkgSha256: the exact installer digest, environment: "fresh-vm",
developerToolsUsed: false, manualDatabaseFixesUsed: false, and checks mapping
install, pairing, reconnect to "passed". This is operator-recorded smoke evidence,
not proof that this script performed a VM rehearsal.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False)
        return result.returncode == 0, result.stdout + result.stderr
    except OSError:
        return False, ""


def fresh_vm_passed(path, digest):
    if not path or not digest:
        return False
    try:
        evidence = json.loads(Path(path).read_text())
        return (isinstance(evidence, dict)
                and type(evidence.get("schemaVersion")) is int
                and evidence["schemaVersion"] == 1
                and evidence.get("status") == "passed"
                and evidence.get("pkgSha256") == digest
                and evidence.get("environment") == "fresh-vm"
                and evidence.get("developerToolsUsed") is False
                and evidence.get("manualDatabaseFixesUsed") is False
                and isinstance(evidence.get("checks"), dict)
                and all(evidence["checks"].get(key) == "passed"
                        for key in ("install", "pairing", "reconnect")))
    except (OSError, ValueError, UnicodeError):
        return False


def tree_manifest(root):
    manifest = {}
    for path in root.rglob("*"):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            manifest[relative] = ("link", os.readlink(path))
        elif path.is_file():
            sha = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    sha.update(chunk)
            manifest[relative] = ("file", path.stat().st_mode & 0o777, sha.hexdigest())
        elif path.is_dir():
            manifest[relative] = ("directory",)
        else:
            raise ValueError("Unsupported payload entry")
    return manifest


def payload_matches(app, pkg):
    # package-dev-pkg.sh installs the app root directly at /Applications/Wonder.app.
    # Reject unfamiliar/multi-component layouts instead of guessing their payload.
    try:
        app_info = plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())
        if (app_info.get("CFBundleIdentifier") != "com.saimun.wonder"
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", str(app_info.get("CFBundleVersion", "")))):
            return False
        with tempfile.TemporaryDirectory(prefix="wonder-package-gate-") as temporary:
            expanded = Path(temporary) / "expanded"
            ok, _ = run("pkgutil", "--expand-full", pkg, str(expanded))
            if not ok:
                return False
            infos = list(expanded.rglob("PackageInfo"))
            if len(infos) != 1:
                return False
            info = ET.parse(infos[0]).getroot()
            if (info.get("install-location") != "/Applications/Wonder.app"
                    or info.get("identifier") != app_info["CFBundleIdentifier"]
                    or info.get("version") != app_info["CFBundleVersion"]
                    or info.find("scripts") is not None):
                return False
            payloads = list(expanded.rglob("Payload"))
            return (len(payloads) == 1 and payloads[0].is_dir()
                    and (payloads[0] / "Contents").is_dir()
                    and tree_manifest(Path(app)) == tree_manifest(payloads[0]))
    except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError):
        return False


def main():
    app, pkg = sys.argv[1:3]
    gate = Path(os.environ.get("WONDER_PACKAGE_GATE_PATH", str(Path(pkg).with_suffix(".acceptance.json"))))
    fresh_input = os.environ.get("WONDER_FRESH_VM_GATE_FILE", "")
    digest = None
    if Path(pkg).is_file():
        with open(pkg, "rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
        if digest is None:
            sha = hashlib.sha256()
            with open(pkg, "rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    sha.update(chunk)
            digest = sha.hexdigest()
    app_valid, _ = run("codesign", "--verify", "--deep", "--strict", app)
    app_details_ok, app_details = run("codesign", "-d", "--verbose=4", app)
    app_team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", app_details, re.MULTILINE)
    app_distribution = (app_details_ok and app_team is not None
                        and "Authority=Developer ID Application:" in app_details)
    pkg_valid, pkg_details = run("pkgutil", "--check-signature", pkg)
    installer_team = re.search(r"Developer ID Installer:.*\(([A-Z0-9]+)\)", pkg_details)
    pkg_distribution = (pkg_valid and installer_team is not None and app_team is not None
                        and installer_team[1] == app_team[1])
    assessed, assessment = run("spctl", "--assess", "--verbose=2", "--type", "install",
                               "--context", "context:primary-signature", pkg)
    notarized = assessed and "source=Notarized Developer ID" in assessment
    passed = {
        "codesignVerify": Path(app).is_dir() and app_valid and app_distribution,
        "pkgutilCheckSignature": digest is not None and pkg_distribution,
        "spctlAssess": notarized,
        "packagePayloadMatchesApp": payload_matches(app, pkg),
        "freshVmGate": fresh_vm_passed(fresh_input, digest),
    }
    ready = all(passed.values())
    report = {"schemaVersion": 2, "appPath": app, "pkgPath": pkg, "pkgSha256": digest,
              **{key: "passed" if value else "blocked" for key, value in passed.items()},
              "freshVmGateInput": fresh_input, "releaseReady": ready}
    gate.parent.mkdir(parents=True, exist_ok=True)
    gate.write_text(json.dumps(report, indent=2) + "\n")
    print(f"package release gates {'passed' if ready else 'blocked; artifact is development-only'}: {gate}",
          file=sys.stdout if ready else sys.stderr)
    return 2 if os.environ.get("WONDER_REQUIRE_RELEASE_GATES") == "1" and not ready else 0


if __name__ == "__main__":
    sys.exit(main())
