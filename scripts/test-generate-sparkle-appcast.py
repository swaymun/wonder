#!/usr/bin/env python3
"""Offline fixtures only: no Keychain access, mounts, signing or publication."""

import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).with_name("generate-sparkle-appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wonder appcast fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dmg = self.root / "Wonder-1.0.51.dmg"
        self.dmg.write_bytes(b"synthetic archive bytes")
        self.output = self.root / "appcast.xml"
        self.url = "https://github.com/swaymun/wonder/releases/download/mac-v1.0.51-beta.1/Wonder-1.0.51.dmg"
        self.info = dict(CFBundleIdentifier="com.saimun.wonder", CFBundleVersion="1.0.51",
                         CFBundleShortVersionString="1.0", LSMinimumSystemVersion="14.0",
                         SUFeedURL=appcast.FEED_URL, SUPublicEDKey=appcast.PUBLIC_KEY,
                         SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
        self.signature = base64.b64encode(b"s" * 64).decode()
        self.public_key = appcast.PUBLIC_KEY
        self.calls = []
        self.mutate_feed = lambda root: None
        self.fail_command = None
        self.fail_feed_verification = False
        self.race_output = False
        self.change_dmg = False

    def command(self, *args):
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        command = Path(args[0]).name
        if command == self.fail_command:
            raise ValueError(f"{command} failed fixture verification")
        if command == "generate_keys":
            self.assertEqual(args[1:], ("--account", appcast.ACCOUNT, "-p"))
            return self.public_key
        if command == "verify-macos-dmg.sh":
            self.assertEqual(Path(args[1]).read_bytes(), self.dmg.read_bytes())
            self.assertEqual(args[2], "1.0.51")
            return "artifact verified"
        if command == "hdiutil":
            if args[1] == "attach":
                self.assertIn("-readonly", args)
                self.assertIn("-nobrowse", args)
                info = Path(args[-1]) / "Wonder.app/Contents/Info.plist"
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps(self.info))
            else:
                self.assertEqual(args[1], "detach")
            return ""
        if command == "generate_appcast":
            self.assertEqual(args[args.index("--maximum-deltas") + 1], "0")
            self.assertEqual(args[args.index("--versions") + 1], "1.0.51")
            self.assertNotIn("--channel", args)
            feed = Path(args[args.index("-o") + 1])
            root = ET.Element("rss", version="2.0")
            item = ET.SubElement(ET.SubElement(root, "channel"), "item")
            for key, info_key in (("version", "CFBundleVersion"),
                                  ("shortVersionString", "CFBundleShortVersionString"),
                                  ("minimumSystemVersion", "LSMinimumSystemVersion")):
                ET.SubElement(item, f"{{{appcast.SPARKLE_NS}}}{key}").text = self.info[info_key]
            prefix = args[args.index("--download-url-prefix") + 1]
            ET.SubElement(item, "enclosure", {
                "url": prefix + self.dmg.name, "length": str(self.dmg.stat().st_size),
                "type": "application/octet-stream", f"{{{appcast.SPARKLE_NS}}}edSignature": self.signature})
            self.mutate_feed(root)
            ET.ElementTree(root).write(feed, encoding="utf-8", xml_declaration=True)
            return ""
        if command == "sign_update":
            self.assertEqual(args[1:3], ("--account", appcast.ACCOUNT))
            if "--verify" in args:
                target = Path(args[4])
                if target.suffix == ".dmg":
                    self.assertEqual(args[5], self.signature)
                else:
                    self.assertIn(b"fixture signed feed", target.read_bytes())
                    if self.fail_feed_verification:
                        raise ValueError("feed signature verification failed")
                    if self.race_output:
                        self.output.write_text("another release owns this output")
                    if self.change_dmg:
                        self.dmg.write_bytes(b"changed source archive")
            else:
                self.assertEqual(args[3], "-p")
                with Path(args[4]).open("ab") as feed:
                    feed.write(b"\n<!-- fixture signed feed -->\n")
            return ""
        raise AssertionError(args)

    def generate(self):
        with patch.object(appcast, "run", self.command), patch.object(appcast.os, "access", return_value=True):
            return appcast.generate(self.dmg, "1.0.51", self.url, self.output)

    def test_success_checks_key_payload_enclosure_and_both_signatures(self):
        result = self.generate()
        self.assertTrue(self.output.is_file())
        self.assertFalse(result["published"])
        self.assertEqual(result["sha256"], appcast.sha256(self.dmg))
        self.assertEqual(result["length"], self.dmg.stat().st_size)
        verifications = [args for args in self.calls if Path(args[0]).name == "sign_update" and "--verify" in args]
        self.assertEqual(len(verifications), 2)
        self.assertEqual(list(self.root.glob(".wonder-appcast-*")), [])
        self.assertTrue(any(args[:2] == ("hdiutil", "detach") for args in self.calls))
        self.assertFalse(any(flag in args for args in self.calls for flag in ("-x", "--ed-key-file", "-s")))

    def test_stable_versioned_tag_is_allowed(self):
        self.url = self.url.replace("mac-v1.0.51-beta.1", "v1.0.51")
        self.generate()

    def test_unsafe_or_mismatched_urls_fail_before_commands(self):
        invalid = [self.url.replace("https://", "http://"),
                   self.url.replace("github.com/", "github.com.evil/"),
                   self.url.replace("swaymun/wonder", "other/wonder"),
                   self.url.replace("download/mac-v1.0.51-beta.1", "latest/download"),
                   self.url.replace("mac-v1.0.51-beta.1", "mac-v1.0.50-beta.1"),
                   self.url.replace("Wonder-1.0.51.dmg", "Wonder-1.0.50.dmg"),
                   self.url + "?raw=1", self.url + "#fragment",
                   self.url.replace("github.com/", "user:password@github.com/"),
                   self.url.replace("Wonder-", "%57onder-"), self.url + "\n"]
        for url in invalid:
            with self.subTest(url=url), self.assertRaises(ValueError):
                appcast.validate_inputs(self.dmg, "1.0.51", url, self.output)
        self.assertEqual(self.calls, [])

    def test_existing_output_and_dangling_symlink_are_never_overwritten(self):
        self.output.write_text("existing feed")
        with self.assertRaises(ValueError):
            self.generate()
        self.assertEqual(self.output.read_text(), "existing feed")
        self.output.unlink()
        self.output.symlink_to(self.root / "missing.xml")
        with self.assertRaises(ValueError):
            self.generate()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(self.calls, [])

    def test_wrong_account_key_fails_before_reading_payload(self):
        self.public_key = base64.b64encode(b"k" * 32).decode()
        with self.assertRaisesRegex(ValueError, "public key"):
            self.generate()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.output.exists())

    def test_signature_or_notarization_gate_failure_writes_nothing(self):
        self.fail_command = "verify-macos-dmg.sh"
        with self.assertRaises(ValueError):
            self.generate()
        self.assertFalse(self.output.exists())
        self.assertFalse(any(Path(args[0]).name == "generate_appcast" for args in self.calls))

    def test_signed_payload_configuration_mismatches_fail_after_detaching(self):
        for key, wrong in (("CFBundleIdentifier", "com.example.other"),
                           ("CFBundleVersion", "1.0.50"), ("SUFeedURL", "https://example.com/appcast.xml"),
                           ("SUPublicEDKey", "wrong key"), ("SUVerifyUpdateBeforeExtraction", False),
                           ("SURequireSignedFeed", False)):
            with self.subTest(key=key), patch.dict(self.info, {key: wrong}):
                self.calls.clear()
                with self.assertRaises(ValueError):
                    self.generate()
                self.assertTrue(any(args[:2] == ("hdiutil", "detach") for args in self.calls))
                self.assertFalse(self.output.exists())

    def test_generated_enclosure_mismatches_are_rejected_before_signing_feed(self):
        for key, wrong in (("url", "https://github.com/swaymun/wonder/releases/latest/download/Wonder.dmg"),
                           ("length", "1"), ("type", "text/plain"),
                           (f"{{{appcast.SPARKLE_NS}}}edSignature", "not a signature")):
            with self.subTest(key=key):
                self.mutate_feed = lambda root, k=key, v=wrong: root.find("./channel/item/enclosure").set(k, v)
                with self.assertRaises(ValueError):
                    self.generate()
                self.assertFalse(self.output.exists())

    def test_wrong_generated_version_or_duplicate_item_is_rejected(self):
        self.mutate_feed = lambda root: setattr(root.find(f"./channel/item/{{{appcast.SPARKLE_NS}}}version"), "text", "1.0.50")
        with self.assertRaisesRegex(ValueError, "version"):
            self.generate()
        self.mutate_feed = lambda root: ET.SubElement(root.find("channel"), "item")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.generate()

    def test_crypto_verification_failure_does_not_publish_output(self):
        self.fail_command = "sign_update"
        with self.assertRaises(ValueError):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_feed_signature_verification_failure_does_not_publish_output(self):
        self.fail_feed_verification = True
        with self.assertRaisesRegex(ValueError, "feed signature"):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_wrong_archive_filename_is_rejected_before_keychain_access(self):
        wrong = self.dmg.with_name("Wonder-1.0.50.dmg")
        self.dmg.rename(wrong)
        self.dmg = wrong
        with self.assertRaisesRegex(ValueError, "Wonder-VERSION.dmg"):
            self.generate()
        self.assertEqual(self.calls, [])

    def test_concurrent_output_creation_is_preserved(self):
        self.race_output = True
        with self.assertRaises(FileExistsError):
            self.generate()
        self.assertEqual(self.output.read_text(), "another release owns this output")

    def test_archive_change_during_generation_does_not_publish_output(self):
        self.change_dmg = True
        with self.assertRaisesRegex(ValueError, "bytes changed"):
            self.generate()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
