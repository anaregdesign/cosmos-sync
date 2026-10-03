"""Security/identity regression checks for publication guards (no registry writes)."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from urllib.request import Request
from unittest.mock import patch
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location("release_verify", Path(__file__).with_name("release_verify.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
SHA = "a" * 40
VERSION = "0.2.0-dev.1"


class ReleaseGuardsTest(unittest.TestCase):
    def test_pub_verification_rejects_dirty_or_mismatched_source_before_registry_reads(self):
        candidates = (
            ("invalid-sha", []),
            (SHA, ["b" * 40]),
            (SHA, [SHA, " M packages/cosmos_sync/lib/cosmos_sync.dart"]),
        )
        for approved, outputs in candidates:
            with self.subTest(approved=approved, outputs=outputs):
                with patch.object(release, "run", side_effect=outputs), patch.object(release, "json_url") as metadata_read, patch.object(release, "safe_open") as archive_read, patch.object(release, "consumer_verify") as consumer:
                    with self.assertRaises(release.ReleaseError):
                        release.pub_verify(VERSION, approved)
                    metadata_read.assert_not_called()
                    archive_read.assert_not_called()
                    consumer.assert_not_called()

    def test_pub_verification_accepts_exact_clean_historical_source_without_main_lookup(self):
        registry = {
            "version": VERSION,
            "pubspec": {"name": "cosmos_sync"},
            "archive_url": "https://pub.dev/api/archives/cosmos_sync-" + VERSION + ".tar.gz",
        }
        with patch.object(release, "run", side_effect=[SHA, ""]) as commands, patch.object(release, "metadata", return_value={"version": VERSION}), patch.object(release, "json_url", return_value=registry), patch.object(release, "safe_open", return_value=io.BytesIO(b"archive")), patch.object(release, "validate_archive", return_value={"archiveSha256": "verified"}), patch.object(release, "consumer_verify", return_value={"liveCloudVerified": False}), patch.object(release, "gh", side_effect=AssertionError("Historical verification must not require current main")):
            evidence = release.pub_verify(VERSION, SHA)
            self.assertEqual(evidence["sourceSha"], SHA)
            self.assertEqual(evidence["version"], VERSION)
            self.assertEqual(commands.call_args_list[0].args, ("git", "rev-parse", "HEAD"))
            self.assertEqual(commands.call_args_list[1].args, ("git", "status", "--porcelain"))

    def test_installed_consumer_requires_isolated_hosted_version_and_source_bytes(self):
        with tempfile.TemporaryDirectory(prefix="cosmos-sync-consumer ") as directory:
            cache = Path(directory) / ".pub-cache"
            package = cache / "hosted/pub.dev" / ("cosmos_sync-" + VERSION)
            shutil.copytree(release.PACKAGE / "lib", package / "lib")
            config = Path(directory) / "package_config.json"
            def write_config(root):
                config.write_text(json.dumps({"packages": [{"name": "cosmos_sync", "rootUri": root}]}))
            write_config(package.as_uri())
            self.assertEqual(release.resolved_consumer_package(config, VERSION, cache), package.resolve())
            (package / "lib/extra.dart").write_text("library;\n")
            with self.assertRaises(release.ReleaseError):
                release.resolved_consumer_package(config, VERSION, cache)
            (package / "lib/extra.dart").unlink()
            for root in (release.PACKAGE.as_uri(), "https://pub.dev/packages/cosmos_sync", (cache / "hosted/pub.dev/cosmos_sync-9.0.0").as_uri()):
                write_config(root)
                with self.assertRaises(release.ReleaseError):
                    release.resolved_consumer_package(config, VERSION, cache)

    def test_approved_mit_files_match_and_pending_license_stays_blocked(self):
        release.verify_license_files("MIT")
        with self.assertRaises(release.ReleaseError):
            release.verify_license_files("Apache-2.0")
        with patch.object(release, "license_pending", return_value=True):
            with self.assertRaises(release.ReleaseError):
                release.verify_license_files("MIT")

    def test_remote_attestation_is_bound_to_platform_digest(self):
        digest = "sha256:" + "a" * 64
        statement = {"_type": "https://in-toto.io/Statement/v0.1", "predicateType": "https://spdx.dev/Document", "predicate": {"SPDXID": "SPDXRef-DOCUMENT"}, "subject": [{"digest": {"sha256": "a" * 64}}]}
        self.assertEqual(release.validate_statement(statement, digest), "https://spdx.dev/Document")
        with self.assertRaises(release.ReleaseError):
            release.validate_statement(statement, "sha256:" + "b" * 64)
        with self.assertRaises(release.ReleaseError):
            release.validate_statement(dict(statement, predicate={}), digest)

    def test_cross_origin_blob_redirect_drops_all_credentials(self):
        request = Request("https://ghcr.io/v2/owned/blobs/digest", headers={"Authorization": "Bearer private", "Cookie": "private", "Proxy-Authorization": "private"})
        redirected = release.SafeRedirect().redirect_request(request, None, 302, "redirect", {}, "https://artifact.example/path")
        self.assertIsNone(redirected.get_header("Authorization"))
        self.assertIsNone(redirected.get_header("Cookie"))
        self.assertIsNone(redirected.get_header("Proxy-authorization"))
        with self.assertRaises(release.ReleaseError):
            release.SafeRedirect().redirect_request(request, None, 302, "redirect", {}, "http://artifact.example/path")

    def test_initial_private_stage_preserves_public_owner_approval(self):
        response = SimpleNamespace(returncode=1, stdout='{"status": "404"}', stderr="gh: Package not found (HTTP 404)")
        with patch.object(release.subprocess, "run", return_value=response):
            self.assertEqual(release.ghcr_stage("public"), {"approvedFinalVisibility": "public", "verificationVisibility": "private", "visibilityTransitionRequired": True})
            self.assertFalse(release.ghcr_stage("private")["visibilityTransitionRequired"])

    def test_existing_visibility_and_access_errors_cannot_be_guessed(self):
        for visibility in ("private", "public"):
            response = SimpleNamespace(returncode=0, stdout=release.json.dumps({"visibility": visibility, "repository": {"full_name": release.REPOSITORY}}))
            with patch.object(release.subprocess, "run", return_value=response):
                self.assertEqual(release.ghcr_stage("public")["verificationVisibility"], visibility)
                if visibility == "public":
                    with self.assertRaises(release.ReleaseError):
                        release.ghcr_stage("private")
        for status in (401, 403, 500):
            response = SimpleNamespace(returncode=1, stdout=release.json.dumps({"status": str(status)}), stderr=f"gh: failure (HTTP {status})")
            with patch.object(release.subprocess, "run", return_value=response):
                with self.assertRaises(release.ReleaseError):
                    release.ghcr_stage("public")

    def test_complete_ci_is_bound_to_current_main_and_all_jobs(self):
        run = {"head_sha": SHA, "head_branch": "main", "event": "push", "conclusion": "success", "status": "completed", "run_number": 10, "id": 123, "html_url": "https://github.com/anaregdesign/cosmos-sync/actions/runs/123"}
        jobs = [{"name": name, "status": "completed", "conclusion": "success"} for name in release.REQUIRED_JOBS]
        with patch.object(release, "gh", side_effect=[{"object": {"sha": SHA}}, {"workflow_runs": [run]}, {"jobs": jobs, "total_count": len(jobs)}]):
            self.assertEqual(len(release.successful_main_ci(SHA)["jobs"]), len(release.REQUIRED_JOBS))
        with patch.object(release, "gh", return_value={"object": {"sha": "b" * 40}}):
            with self.assertRaises(release.ReleaseError):
                release.successful_main_ci(SHA)
        for bad in ("skipped", "failure", None):
            failing = copy.deepcopy(jobs)
            failing[0]["conclusion"] = bad
            with patch.object(release, "gh", side_effect=[{"object": {"sha": SHA}}, {"workflow_runs": [run]}, {"jobs": failing}]):
                with self.assertRaises(release.ReleaseError):
                    release.successful_main_ci(SHA)

    def test_latest_failed_run_cannot_reuse_older_success(self):
        older = {"head_sha": SHA, "head_branch": "main", "event": "push", "conclusion": "success", "status": "completed", "run_number": 10}
        newer = dict(older, run_number=11, conclusion="failure")
        with patch.object(release, "gh", side_effect=[{"object": {"sha": SHA}}, {"workflow_runs": [older, newer]}]):
            with self.assertRaises(release.ReleaseError):
                release.successful_main_ci(SHA)

    def test_missing_approval_and_dirty_source_are_blocked(self):
        meta = {"name": "cosmos_sync", "version": VERSION}
        for dirty, env in ((" M pubspec.yaml", {}), ("", {}), ("", {"RELEASE_APPROVED_SHA": "b" * 40})):
            with patch.object(release, "metadata", return_value=meta.copy()), patch.object(release, "license_pending", return_value=False), patch.object(release, "run", side_effect=[SHA, dirty]), patch.dict(release.os.environ, env, clear=True):
                with self.assertRaises(release.ReleaseError):
                    release.preflight("ghcr", SHA, VERSION)

    def test_platforms_and_attestations_are_both_required(self):
        entries = []
        for arch in ("amd64", "arm64"):
            digest = "sha256:" + ("1" if arch == "amd64" else "2") * 64
            entries.append({"digest": digest, "platform": {"os": "linux", "architecture": arch}})
            entries.append({"platform": {"os": "unknown", "architecture": "unknown"}, "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": digest}})
        release.validate_manifest({"schemaVersion": 2, "manifests": entries})
        for removed in (0, 1, 2, 3):
            with self.assertRaises(release.ReleaseError):
                release.validate_manifest({"schemaVersion": 2, "manifests": entries[:removed] + entries[removed + 1:]})

    def test_image_revision_entrypoint_and_nonroot(self):
        image = {"os": "linux", "architecture": "arm64", "config": {"User": "nonroot:nonroot", "Entrypoint": ["/cosmos-sync-bff"], "Labels": {"org.opencontainers.image.source": release.SOURCE, "org.opencontainers.image.revision": SHA, "org.opencontainers.image.version": VERSION, "org.opencontainers.image.licenses": "MIT"}}}
        release.validate_image(image, SHA, VERSION, "arm64")
        for key, value in (("User", "root"), ("Entrypoint", ["/bin/sh"])):
            changed = copy.deepcopy(image)
            changed["config"][key] = value
            with self.assertRaises(release.ReleaseError):
                release.validate_image(changed, SHA, VERSION, "arm64")
        with self.assertRaises(release.ReleaseError):
            release.validate_image(image, "b" * 40, VERSION, "arm64")

    def test_public_archive_matches_reviewed_source(self):
        files = {str(p.relative_to(release.PACKAGE)): p.read_bytes() for p in (release.PACKAGE / "lib").rglob("*.dart")}
        for name in ("pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md"):
            files[name] = (release.PACKAGE / name).read_bytes()
        for path in (release.PACKAGE / "doc").rglob("*.md"):
            files[str(path.relative_to(release.PACKAGE))] = path.read_bytes()

        def archive(contents):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w:gz") as bundle:
                for name, data in contents.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    bundle.addfile(info, io.BytesIO(data))
            return output.getvalue()

        raw = archive(files)
        self.assertEqual(release.validate_archive(raw)["verifiedFiles"], len(files))
        for name, data in (("lib/extra.dart", b"unexpected"), ("../secret.key", b"private"), ("bin/fixture.dart", b"test"), ("pubspec.yaml", b"wrong version")):
            with self.assertRaises(release.ReleaseError):
                release.validate_archive(archive(dict(files, **{name: data})))
        with self.assertRaises(release.ReleaseError):
            release.validate_archive(raw, "0" * 64)


if __name__ == "__main__":
    unittest.main()
