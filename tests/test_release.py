"""Offline checks for the versions and files exposed to players' updaters."""
import configparser
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools import release


class FakeGitHub:
    def __init__(self, releases=()):
        self.releases = {item["tag_name"]: dict(item) for item in releases}
        self.assets = {}
        self.latest = None
        self.fail_upload = False

    def __call__(self, *args):
        if args[0] == "api":
            return "\n".join(json.dumps(item) for item in self.releases.values())
        action, tag = args[1:3]
        if action == "create":
            self.releases[tag] = dict(tag_name=tag, draft=True, prerelease=False,
                                      target_commitish=args[args.index("--target") + 1])
        elif action == "upload":
            if self.fail_upload:
                raise subprocess.CalledProcessError(1, ["gh", *args])
            self.assets[tag] = {Path(arg).name for arg in args[3:args.index("--repo")]}
        elif action == "edit":
            if not self.assets.get(tag):
                raise AssertionError("Release was made visible before assets were uploaded")
            self.releases[tag]["draft"] = False
            self.releases[tag]["prerelease"] = False
            if "--latest=true" in args:
                self.latest = tag
        else:
            raise AssertionError(args)
        return ""


def published(tag):
    return dict(tag_name=tag, draft=False, prerelease=False, target_commitish="abc")


class VersionTests(unittest.TestCase):
    def select(self, **overrides):
        args = dict(base="0.33.2.3", event="push", ref="refs/heads/main",
                    run_number="42", run_attempt="1")
        args.update(overrides)
        return release.select_version(**args)

    def test_each_branch_build_and_manual_run_publishes_without_a_version_bump(self):
        for overrides in ({}, {"ref": "refs/heads/codex/performance-0.33.2.2"},
                          {"event": "workflow_dispatch"}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.select(**overrides), ("0.33.2.3.42.1", True))

    def test_pull_request_builds_without_publishing(self):
        self.assertEqual(self.select(event="pull_request", ref="refs/pull/7/merge"),
                         ("0.33.2.3.42.1", False))

    def test_next_build_rerun_and_base_bump_are_newer(self):
        previous = release.version_key(self.select()[0])
        for overrides in ({"run_number": "43"}, {"run_attempt": "2"}, {"base": "0.33.2.4"}):
            with self.subTest(overrides=overrides):
                self.assertGreater(release.version_key(self.select(**overrides)[0]), previous)
        self.assertGreater(release.version_key("0.33.2.3.43.1"),
                           release.version_key("0.33.2.3.42.9"))

    def test_explicit_numeric_tag_and_manual_version(self):
        for overrides in ({"ref": "refs/tags/v0.33.2.4"},
                          {"event": "workflow_dispatch", "requested": "0.33.2.4"}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.select(**overrides), ("0.33.2.4", True))

    def test_invalid_versions_and_workflow_events_are_rejected(self):
        for version in ("", "1.2-beta", "v1.2", "1.2\nrelease=true", '1.2;$(echo unsafe)',
                        "-1.2", "1..2", "1.9223372036854775808"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.version_key(version)
        for overrides in ({"event": "pull_request_target"}, {"run_number": "0"},
                          {"run_attempt": ""}, {"ref": "refs/tags/vbad"},
                          {"event": "workflow_dispatch", "requested": "1.2-beta"}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.select(**overrides)

    def test_numeric_order_matches_updater_examples_and_zero_padding(self):
        self.assertGreater(release.version_key("0.32.1"), release.version_key("0.32.0.1"))
        self.assertGreater(release.version_key("0.32.0.1"), release.version_key("0.32.0"))
        self.assertEqual(release.version_key("1.2.0.0"), release.version_key("1.2"))
        self.assertGreater(release.version_key("1.2.10"), release.version_key("1.2.9"))

    def test_version_command_writes_github_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "outputs"
            env = dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/main",
                       GITHUB_RUN_NUMBER="42", GITHUB_RUN_ATTEMPT="1", RELEASE_VERSION="",
                       GITHUB_OUTPUT=str(output))
            subprocess.run([sys.executable, str(Path(release.__file__)), "version"],
                           env=env, check=True, capture_output=True, text=True)
            cfg = configparser.ConfigParser()
            cfg.read(release.ROOT / "game/pc/version.cfg")
            base = cfg["pc"]["version"].strip('"')
            self.assertEqual(output.read_text(), f"version={base}.42.1\nrelease=true\n")


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dist = Path(self.tmp.name)
        manifest = []
        for name, contents in (("DroneFlames.exe", b"executable"),
                               ("DroneFlames-libs-r1.zip", b"libraries")):
            (self.dist / name).write_bytes(contents)
            manifest.append(f"{hashlib.sha256(contents).hexdigest()}  {name}\n")
        (self.dist / "SHA256SUMS.txt").write_text("".join(manifest))
        self.github = FakeGitHub()

    def publish(self, version="0.33.2.3.42.1"):
        with patch.object(release, "gh", self.github):
            release.publish(version, "owner/game", "abc", self.dist)

    def test_complete_release_is_visible_and_latest(self):
        self.publish()
        tag = "v0.33.2.3.42.1"
        self.assertFalse(self.github.releases[tag]["draft"])
        self.assertEqual(self.github.latest, tag)
        self.assertEqual(self.github.assets[tag], {"DroneFlames.exe", "DroneFlames-libs-r1.zip",
                                                  "SHA256SUMS.txt"})

    def test_older_branch_build_does_not_replace_latest(self):
        self.github = FakeGitHub([published("v0.33.2.4.1.1")])
        self.github.latest = "v0.33.2.4.1.1"
        self.publish()
        self.assertEqual(self.github.latest, "v0.33.2.4.1.1")
        self.assertFalse(self.github.releases["v0.33.2.3.42.1"]["draft"])

    def test_drafts_and_prereleases_do_not_block_latest(self):
        draft = published("v99.1")
        draft["draft"] = True
        prerelease = published("v98.1")
        prerelease["prerelease"] = True
        self.github = FakeGitHub([draft, prerelease])
        self.publish()
        self.assertEqual(self.github.latest, "v0.33.2.3.42.1")

    def test_upload_failure_leaves_hidden_draft_and_can_resume(self):
        self.github.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.github.releases["v0.33.2.3.42.1"]["draft"])
        self.assertIsNone(self.github.latest)
        self.github.fail_upload = False
        self.publish()
        self.assertFalse(self.github.releases["v0.33.2.3.42.1"]["draft"])

    def test_published_assets_cannot_be_overwritten(self):
        self.publish()
        with self.assertRaisesRegex(ValueError, "already published"):
            self.publish()

    def test_draft_for_another_commit_cannot_be_reused(self):
        self.github = FakeGitHub([dict(tag_name="v0.33.2.3.42.1", draft=True,
                                      prerelease=False, target_commitish="other")])
        with self.assertRaisesRegex(ValueError, "different commit"):
            self.publish()
        self.assertFalse(self.github.assets)

    def test_corrupt_or_missing_artifacts_never_create_a_release(self):
        for name in ("DroneFlames.exe", "DroneFlames-libs-r1.zip"):
            with self.subTest(name=name):
                asset = self.dist / name
                original = asset.read_bytes()
                asset.write_bytes(b"corrupt")
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    self.publish()
                asset.write_bytes(original)
        (self.dist / "DroneFlames-libs-r1.zip").unlink()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.publish()
        self.assertFalse(self.github.releases)

    def test_github_auth_or_api_failure_never_creates_a_release(self):
        with patch.object(release, "gh", side_effect=subprocess.CalledProcessError(1, ["gh", "api"])) as api:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish("0.33.2.3.42.1", "owner/game", "abc", self.dist)
            self.assertEqual(api.call_count, 1)


if __name__ == "__main__":
    unittest.main()
