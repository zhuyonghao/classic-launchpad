#!/usr/bin/env python3
"""Exercise the publisher with an isolated fake gh; no GitHub access is used."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).with_name("publish-release.sh").resolve()
TAG = "v1.1.14"
REPOSITORY = "example/classic-launchpad"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
ASSET_NAMES = (
    f"ClassicLaunchpad-{TAG}-arm64.zip",
    f"ClassicLaunchpad-{TAG}-x86_64.zip",
    "SHA256SUMS.txt",
)


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.assets = self.root / "build" / "release"
        self.assets.mkdir(parents=True)
        for name, content in zip(ASSET_NAMES[:2], (b"arm64 archive payload", b"x86_64 archive payload")):
            (self.assets / name).write_bytes(content)
        checksums = "".join(
            f"{hashlib.sha256((self.assets / name).read_bytes()).hexdigest()}  {name}\n"
            for name in ASSET_NAMES[:2]
        )
        (self.assets / ASSET_NAMES[2]).write_text(checksums, encoding="utf-8")
        self.config_path = self.root / "gh-config.json"
        self.log_path = self.root / "gh-calls.jsonl"
        executable_directory = self.root / "bin"
        executable_directory.mkdir()
        fake_gh = executable_directory / "gh"
        fake_gh.write_text(
            f"#!{sys.executable}\n" + textwrap.dedent("""\
                import json
                import os
                from pathlib import Path
                import sys

                args = sys.argv[1:]
                if len(args) >= 2 and args[0] == "release":
                    command = args[1]
                elif args and args[0] == "api":
                    command = "api"
                else:
                    command = "unexpected"
                with Path(os.environ["GH_FAKE_LOG"]).open("a", encoding="utf-8") as log:
                    log.write(json.dumps({"command": command, "args": args}) + "\\n")
                config = json.loads(Path(os.environ["GH_FAKE_CONFIG"]).read_text())
                failure = config.get("exit_codes", {}).get(command)
                if failure:
                    print(f"simulated {command} failure", file=sys.stderr)
                    sys.exit(failure)
                if command == "view":
                    status = config["release_status"]
                    if status == "missing":
                        print("release not found", file=sys.stderr)
                        sys.exit(1)
                    if status == "draft":
                        print("true")
                    elif status == "published":
                        print("false")
                    else:
                        print(status)
                elif command == "api":
                    print(json.dumps(config["api_response"]))
                elif command not in {"create", "upload", "edit"}:
                    print(f"unexpected fake gh command: {args!r}", file=sys.stderr)
                    sys.exit(99)
            """),
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": str(executable_directory) + os.pathsep + self.environment.get("PATH", ""),
            "GH_REPO": REPOSITORY,
            "GITHUB_REF_NAME": TAG,
            "GITHUB_SHA": COMMIT,
            "GH_FAKE_CONFIG": str(self.config_path),
            "GH_FAKE_LOG": str(self.log_path),
        })

    def configuration(self, release_status="draft"):
        return {
            "release_status": release_status,
            "api_response": {
                "draft": release_status != "published",
                "assets": [
                    {
                        "name": name,
                        "state": "uploaded",
                        "size": (self.assets / name).stat().st_size,
                        "digest": "sha256:" + hashlib.sha256((self.assets / name).read_bytes()).hexdigest(),
                    }
                    for name in ASSET_NAMES
                ],
            },
        }

    def publish(self, configuration=None):
        if configuration is None:
            configuration = self.configuration()
        self.config_path.write_text(json.dumps(configuration), encoding="utf-8")
        self.log_path.unlink(missing_ok=True)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def calls(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]

    def commands(self):
        return [call["command"] for call in self.calls()]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_draft_preserved(self, result):
        self.assertNotEqual(result.returncode, 0, "invalid or failed uploads must not be published")
        self.assertNotIn("edit", self.commands())

    def assert_upload_and_publish_arguments(self):
        calls = {call["command"]: call["args"] for call in self.calls()}
        self.assertEqual(calls["upload"], [
            "release", "upload", TAG, "--repo", REPOSITORY, "--clobber",
            *(f"build/release/{name}" for name in ASSET_NAMES),
        ])
        self.assertEqual(calls["api"], ["api", f"repos/{REPOSITORY}/releases/tags/{TAG}"])
        self.assertEqual(calls["edit"], [
            "release", "edit", TAG, "--repo", REPOSITORY, "--draft=false", "--latest",
        ])

    def test_new_release_is_drafted_uploaded_verified_then_published(self):
        result = self.publish(self.configuration("missing"))
        self.assert_success(result)
        self.assertEqual(self.commands(), ["view", "create", "upload", "api", "edit"])
        calls = {call["command"]: call["args"] for call in self.calls()}
        self.assertEqual(calls["view"], [
            "release", "view", TAG, "--repo", REPOSITORY, "--json", "isDraft", "--jq", ".isDraft",
        ])
        self.assertEqual(calls["create"], [
            "release", "create", TAG, "--repo", REPOSITORY, "--verify-tag",
            "--target", COMMIT, "--title", "启动台 1.1.14", "--draft", "--generate-notes",
        ])
        self.assert_upload_and_publish_arguments()

    def test_new_release_uses_existing_version_notes(self):
        notes = self.root / ".github" / "release-notes" / f"{TAG}.md"
        notes.parent.mkdir(parents=True)
        notes.write_text("Release notes for this version.\n", encoding="utf-8")
        result = self.publish(self.configuration("missing"))
        self.assert_success(result)
        create = next(call["args"] for call in self.calls() if call["command"] == "create")
        self.assertEqual(create[-2:], ["--notes-file", f".github/release-notes/{TAG}.md"])
        self.assertNotIn("--generate-notes", create)

    def test_existing_draft_resumes_without_creating_another_release(self):
        result = self.publish()
        self.assert_success(result)
        self.assertEqual(self.commands(), ["view", "upload", "api", "edit"])
        self.assert_upload_and_publish_arguments()

    def test_published_release_preserves_existing_assets_without_any_write(self):
        configuration = self.configuration("published")
        # Previously published bytes may differ from a newly rebuilt local archive.
        for asset in configuration["api_response"]["assets"]:
            asset.update(size=asset["size"] + 17, digest="sha256:" + "0" * 64)
        result = self.publish(configuration)
        self.assert_success(result)
        self.assertEqual(self.commands(), ["view", "api"])

    def test_upload_failure_does_not_verify_or_publish_a_partial_release(self):
        configuration = self.configuration("missing")
        configuration["exit_codes"] = {"upload": 23}
        result = self.publish(configuration)
        self.assert_draft_preserved(result)
        self.assertEqual(self.commands(), ["view", "create", "upload"])

    def test_api_failure_does_not_publish(self):
        configuration = self.configuration()
        configuration["exit_codes"] = {"api": 24}
        result = self.publish(configuration)
        self.assert_draft_preserved(result)
        self.assertEqual(self.commands(), ["view", "upload", "api"])

    def test_missing_or_incomplete_remote_asset_does_not_publish(self):
        for index, name in enumerate(ASSET_NAMES):
            for condition in ("missing", "uploading", "empty"):
                with self.subTest(asset=name, condition=condition):
                    configuration = self.configuration()
                    remote = configuration["api_response"]["assets"]
                    if condition == "missing":
                        del remote[index]
                    elif condition == "uploading":
                        remote[index]["state"] = "new"
                    else:
                        remote[index]["size"] = 0
                    result = self.publish(configuration)
                    self.assert_draft_preserved(result)
                    self.assertEqual(self.commands(), ["view", "upload", "api"])

    def test_remote_size_mismatch_does_not_publish(self):
        for index, name in enumerate(ASSET_NAMES):
            with self.subTest(asset=name):
                configuration = self.configuration()
                configuration["api_response"]["assets"][index]["size"] += 1
                result = self.publish(configuration)
                self.assert_draft_preserved(result)
                self.assertIn("size does not match", result.stderr)

    def test_remote_sha256_mismatch_does_not_publish(self):
        for index, name in enumerate(ASSET_NAMES):
            with self.subTest(asset=name):
                configuration = self.configuration()
                configuration["api_response"]["assets"][index]["digest"] = "sha256:" + "0" * 64
                result = self.publish(configuration)
                self.assert_draft_preserved(result)
                self.assertIn("checksum does not match", result.stderr)

    def test_optional_remote_digests_can_be_absent_null_or_empty(self):
        for digest in ("absent", None, ""):
            with self.subTest(digest=digest):
                configuration = self.configuration()
                for asset in configuration["api_response"]["assets"]:
                    if digest == "absent":
                        del asset["digest"]
                    else:
                        asset["digest"] = digest
                result = self.publish(configuration)
                self.assert_success(result)
                self.assertEqual(self.commands(), ["view", "upload", "api", "edit"])

    def test_incomplete_published_release_is_reported_without_any_write(self):
        configuration = self.configuration("published")
        configuration["api_response"]["assets"].pop()
        result = self.publish(configuration)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), ["view", "api"])

    def test_unknown_release_state_fails_without_any_write(self):
        configuration = self.configuration("unknown")
        result = self.publish(configuration)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), ["view"])

    def test_missing_or_empty_local_assets_fail_before_any_github_call(self):
        configuration = self.configuration()
        for name in ASSET_NAMES:
            asset = self.assets / name
            original = asset.read_bytes()
            for condition in ("missing", "empty"):
                with self.subTest(asset=name, condition=condition):
                    if condition == "missing":
                        asset.unlink()
                    else:
                        asset.write_bytes(b"")
                    try:
                        result = self.publish(copy.deepcopy(configuration))
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(self.calls(), [])
                    finally:
                        asset.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
