#!/usr/bin/env python3
"""Fail-closed release checks and post-publication evidence; never publishes."""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.error import HTTPError
from urllib.parse import unquote, urlencode, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/cosmos_sync"
REPOSITORY = "anaregdesign/cosmos-sync"
IMAGE = "ghcr.io/anaregdesign/cosmos-sync-bff"
SOURCE = "https://github.com/" + REPOSITORY
PLATFORMS = {"linux/amd64", "linux/arm64"}
REQUIRED_JOBS = {
    "bff", "dart", "browser", "cosmos-emulator", "flutter-macos", "flutter-web", "container",
    "cross-stack",
    "release-tools",
}
SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


class ReleaseError(Exception):
    pass


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        old, new = urlparse(request.full_url), urlparse(url)
        require(new.scheme == "https", "Registry redirect must remain HTTPS")
        redirected = super().redirect_request(request, response, code, message, headers, url)
        if (old.hostname, old.port or 443) != (new.hostname, new.port or 443):
            redirected.remove_header("Authorization")
            redirected.remove_header("Proxy-authorization")
            redirected.remove_header("Cookie")
        return redirected


def safe_open(request):
    url = request.full_url if isinstance(request, Request) else request
    require(urlparse(url).scheme == "https", "Registry reads require HTTPS")
    return build_opener(SafeRedirect()).open(request, timeout=30)


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=180)
    require(result.returncode == 0, f"Command failed: {args[0]} {args[1] if len(args) > 1 else ''}. Check authentication, network and tool output locally.")
    return result.stdout.strip()


def gh(path):
    return json.loads(run("gh", "api", "-H", "Accept: application/vnd.github+json", path))


def ghcr_stage(final_visibility):
    """A missing initial package is private; retain the owner's final approval."""
    require(final_visibility in ("private", "public"), "Record approved final GHCR visibility explicitly")
    response = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", "orgs/anaregdesign/packages/container/cosmos-sync-bff"], cwd=ROOT, text=True, capture_output=True, timeout=30)
    if response.returncode == 0:
        package = json.loads(response.stdout)
        current = package.get("visibility")
        require(current in ("private", "public"), "Existing package has an unsupported visibility")
        require(package.get("repository", {}).get("full_name") == REPOSITORY, "Existing GHCR name belongs to another repository")
        require(current != "public" or final_visibility == "public", "An existing public package cannot satisfy a private release approval")
    else:
        try:
            status = str(json.loads(response.stdout).get("status", ""))
        except ValueError:
            status = ""
        require(status == "404" or "(HTTP 404)" in response.stderr, "Cannot inspect GHCR stage: authorized package metadata access is required")
        current = "private"
    return {"approvedFinalVisibility": final_visibility, "verificationVisibility": current, "visibilityTransitionRequired": current != final_visibility}


def json_url(url, headers=None):
    with safe_open(Request(url, headers=headers or {})) as response:
        return json.load(response)


def metadata():
    text = (PACKAGE / "pubspec.yaml").read_text()
    values = {}
    for field in ("name", "version", "repository", "issue_tracker"):
        match = re.search(r"^" + field + r":\s*(\S+)\s*$", text, re.MULTILINE)
        require(match is not None, "Missing pubspec field: " + field)
        values[field] = match[1]
    require(values["name"] == "cosmos_sync", "Unexpected package name")
    require(SEMVER.fullmatch(values["version"]), "Invalid release version")
    require(values["repository"] == SOURCE, "Unexpected source repository")
    require("dependency_overrides:" not in text, "Release must not depend on dependency overrides")
    return values


def license_pending(path):
    if not path.is_file():
        return True
    text = path.read_text()
    return len(text.strip()) < 100 or any(term in text.lower() for term in (
        "unlicensed", "no public license", "license decision", "license pending",
    ))


def verify_license_files(license_id):
    require(license_id == "MIT", "The owner approved MIT; record RELEASE_LICENSE_SPDX=MIT")
    files = (ROOT / "LICENSE", ROOT / "bff/LICENSE", PACKAGE / "LICENSE")
    require(all(not license_pending(path) for path in files), "Replace pending licenses before distribution")
    contents = [path.read_bytes() for path in files]
    require(len(set(contents)) == 1 and contents[0].startswith(b"MIT License\n"), "Repository, BFF and SDK must carry the identical approved MIT license")


def successful_main_ci(sha):
    ref = gh(f"repos/{REPOSITORY}/git/ref/heads/main")
    require(ref["object"]["sha"] == sha, "Approved SHA is no longer the current main commit")
    query = urlencode({"head_sha": sha, "event": "push", "branch": "main", "per_page": 100})
    runs = gh(f"repos/{REPOSITORY}/actions/workflows/ci.yml/runs?{query}")["workflow_runs"]
    matching = [r for r in runs if r.get("head_sha") == sha and r.get("event") == "push" and r.get("head_branch") == "main"]
    require(matching, "No main push CI exists for the approved commit")
    latest = max(matching, key=lambda r: r["run_number"])
    require(latest.get("status") == "completed" and latest.get("conclusion") == "success", "The latest main CI is incomplete or failed")
    response = gh(f"repos/{REPOSITORY}/actions/runs/{latest['id']}/jobs?filter=latest&per_page=100")
    jobs = response["jobs"]
    require(response.get("total_count", len(jobs)) == len(jobs), "CI job list exceeds the verified page")
    require(REQUIRED_JOBS.issubset({job["name"] for job in jobs}), "Required CI jobs are missing")
    require(all(job.get("status") == "completed" and job.get("conclusion") == "success" for job in jobs), "CI contains an incomplete, skipped or failed job")
    return {"url": latest["html_url"], "jobs": sorted(job["name"] for job in jobs)}


def preflight(target, sha=None, version=None):
    result = metadata()
    result["sourceSha"] = run("git", "rev-parse", "HEAD")
    pending = [str(p.relative_to(ROOT)) for p in (ROOT / "LICENSE", ROOT / "bff/LICENSE", PACKAGE / "LICENSE") if license_pending(p)]
    result["pendingLicenseFiles"] = pending
    result["status"] = "ready_for_owner_review" if target == "prepare" else "approved_source_verified"
    if target == "prepare":
        return result
    require(sha is not None and SHA.fullmatch(sha), "Use a full lowercase source SHA")
    require(version is not None and SEMVER.fullmatch(version), "Use an approved semantic version")
    require(sha == result["sourceSha"], "Checked-out source differs from approved SHA")
    require(version == result["version"], "Version differs from pubspec.yaml")
    require(not run("git", "status", "--porcelain"), "Release source must have a clean working tree")
    require(not pending, "Replace pending licenses with the owner's approved license before distribution")
    require(os.environ.get("RELEASE_APPROVED_SHA") == sha, "RELEASE_APPROVED_SHA does not match the candidate")
    require(os.environ.get("RELEASE_APPROVED_VERSION") == version, "RELEASE_APPROVED_VERSION does not match the candidate")
    license_id = os.environ.get("RELEASE_LICENSE_SPDX", "")
    require(license_id and re.fullmatch(r"[A-Za-z0-9.+-]+", license_id) and license_id != "UNLICENSED", "Set the owner's approved SPDX license identifier")
    verify_license_files(license_id)
    if target == "ghcr":
        require(os.environ.get("GHCR_PUBLISH_ENABLED") == "true", "GHCR publication has not been enabled after approval")
        final_visibility = os.environ.get("GHCR_RELEASE_VISIBILITY")
        require(final_visibility in ("private", "public"), "Record owner-approved final GHCR visibility explicitly")
    else:
        require(os.environ.get("PUB_PUBLICATION_APPROVED") == "true", "Public package disclosure and first publication are not approved")
    result["ci"] = successful_main_ci(sha)
    result["licenseSpdx"] = license_id
    if target == "ghcr":
        result["distribution"] = ghcr_stage(final_visibility)
    return result


def validate_manifest(manifest):
    require(manifest.get("schemaVersion") == 2, "Invalid OCI index")
    platforms = set()
    attested = set()
    for entry in manifest.get("manifests", []):
        platform = entry.get("platform", {})
        name = platform.get("os", "") + "/" + platform.get("architecture", "")
        if name in PLATFORMS:
            platforms.add(name)
        if entry.get("annotations", {}).get("vnd.docker.reference.type") == "attestation-manifest":
            attested.add(entry["annotations"].get("vnd.docker.reference.digest"))
    require(platforms == PLATFORMS, "Image must contain both Linux amd64 and arm64 variants")
    runnable = [m for m in manifest["manifests"] if m.get("platform", {}).get("os") == "linux"]
    require(len(runnable) == 2, "Image must contain exactly the two reviewed runnable variants")
    require(all(m["digest"] in attested for m in runnable), "A platform lacks registry-attached attestations")


def validate_image(config, sha, version, architecture):
    require(config.get("os") == "linux" and config.get("architecture") == architecture, "Pulled image architecture differs from requested platform")
    runtime = config.get("config", {})
    require(runtime.get("User") in ("nonroot:nonroot", "65532:65532", "65532"), "Container must run as nonroot")
    labels = runtime.get("Labels", {})
    for key, value in {"source": SOURCE, "revision": sha, "version": version}.items():
        require(labels.get("org.opencontainers.image." + key) == value, "Container metadata does not match approved " + key)
    require(labels.get("org.opencontainers.image.licenses") == "MIT", "Container must declare the owner-approved MIT license")
    require(runtime.get("Entrypoint") == ["/cosmos-sync-bff"], "Unexpected container entrypoint")


def anonymous_visibility(digest, expected):
    token_url = "https://ghcr.io/token?" + urlencode({"service": "ghcr.io", "scope": "repository:anaregdesign/cosmos-sync-bff:pull"})
    try:
        token = json_url(token_url).get("token")
        require(isinstance(token, str) and token, "Invalid anonymous registry token response")
        manifest = json_url(f"https://ghcr.io/v2/anaregdesign/cosmos-sync-bff/manifests/{digest}", {
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
        })
        require(expected == "public", "Private image unexpectedly allows anonymous manifest reads")
        validate_manifest(manifest)
        return "anonymous_manifest_verified"
    except HTTPError as error:
        require(expected == "private" and error.code in (401, 403), "Anonymous registry access failed without proving expected private visibility")
        return "anonymous_access_denied"


def registry_pull_token(authenticated):
    url = "https://ghcr.io/token?" + urlencode({"service": "ghcr.io", "scope": "repository:anaregdesign/cosmos-sync-bff:pull"})
    headers = {}
    if authenticated:
        credential = os.environ.get("GH_TOKEN") or run("gh", "auth", "token")
        actor = os.environ.get("GITHUB_ACTOR") or gh("user")["login"]
        headers["Authorization"] = "Basic " + base64.b64encode((actor + ":" + credential).encode()).decode()
    token = json_url(url, headers).get("token")
    require(isinstance(token, str) and token, "Missing scoped registry pull token")
    return token


def registry_statement(digest, token):
    require(DIGEST.fullmatch(digest), "Invalid attestation layer digest")
    request = Request(f"https://ghcr.io/v2/anaregdesign/cosmos-sync-bff/blobs/{digest}", headers={"Authorization": "Bearer " + token})
    with safe_open(request) as response:
        raw = response.read(16 * 1024 * 1024 + 1)
    require(len(raw) <= 16 * 1024 * 1024, "Attestation exceeds the reviewed read bound")
    require(hashlib.sha256(raw).hexdigest() == digest[7:], "Attestation layer checksum mismatch")
    return json.loads(raw)


def validate_statement(statement, image_digest):
    require(statement.get("_type") in ("https://in-toto.io/Statement/v0.1", "https://in-toto.io/Statement/v1"), "Unsupported attestation statement type")
    subjects = [s.get("digest", {}).get("sha256") for s in statement.get("subject", [])]
    require(image_digest[7:] in subjects, "Attestation subject differs from the platform manifest")
    predicate = statement.get("predicateType")
    require(isinstance(predicate, str) and statement.get("predicate"), "Missing attestation predicate")
    return predicate


def ghcr_verify(digest, sha, version, visibility):
    require(DIGEST.fullmatch(digest), "Use the image index SHA256 digest")
    require(SHA.fullmatch(sha) and SEMVER.fullmatch(version), "Invalid source SHA/version")
    package = gh("orgs/anaregdesign/packages/container/cosmos-sync-bff")
    require(package.get("visibility") == visibility, "GHCR package visibility differs from approved visibility; no automatic visibility change is performed")
    require(package.get("repository", {}).get("full_name") == REPOSITORY, "GHCR package is not linked to this repository")
    reference = IMAGE + "@" + digest
    index = json.loads(run("docker", "buildx", "imagetools", "inspect", "--raw", reference))
    validate_manifest(index)
    token = registry_pull_token(visibility == "private")
    evidence = {"image": reference, "sourceSha": sha, "version": version, "visibility": visibility, "licenseSpdx": "MIT", "platforms": []}
    for architecture in ("amd64", "arm64"):
        platform = "linux/" + architecture
        entry = next(m for m in index["manifests"] if m.get("platform", {}).get("os") == "linux" and m["platform"].get("architecture") == architecture)
        require(DIGEST.fullmatch(entry["digest"]), "Invalid platform manifest digest")
        # Classic daemon image stores cannot retain both architectures under
        # the same index-digest reference. Pull the selected immutable child;
        # the reviewed parent index still binds its platform and attestations.
        child_reference = IMAGE + "@" + entry["digest"]
        run("docker", "pull", "--platform=" + platform, child_reference)
        config = json.loads(run("docker", "buildx", "imagetools", "inspect", reference, "--format", '{{json (index .Image "' + platform + '")}}'))
        validate_image(config, sha, version, architecture)
        attestation = next(m for m in index["manifests"] if m.get("annotations", {}).get("vnd.docker.reference.digest") == entry["digest"])
        attached = json.loads(run("docker", "buildx", "imagetools", "inspect", "--raw", IMAGE + "@" + attestation["digest"]))
        predicates = {validate_statement(registry_statement(layer["digest"], token), entry["digest"]) for layer in attached["layers"]}
        require(any(p.startswith("https://slsa.dev/provenance/") for p in predicates), "Missing bound SLSA provenance for " + platform)
        require("https://spdx.dev/Document" in predicates, "Missing bound SPDX SBOM for " + platform)
        evidence["platforms"].append({"platform": platform, "manifestDigest": entry["digest"], "pulledImage": child_reference, "authenticatedPull": True, "attestationSubjectBinding": entry["digest"], "attestationLayerSha256Verified": True, "provenance": "BuildKit (not a signed GitHub attestation)", "sbom": "SPDX"})
    evidence["anonymousAccess"] = anonymous_visibility(digest, visibility)
    return evidence


def validate_archive(raw, expected_hash=None):
    actual = hashlib.sha256(raw).hexdigest()
    require(not expected_hash or actual == expected_hash, "Published archive checksum differs from registry metadata")
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        files = {}
        total = 0
        for index, member in enumerate(archive):
            require(index < 10000, "Archive contains too many members")
            name = member.name.removeprefix("./")
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts, "Archive contains an unsafe path")
            require(not member.issym() and not member.islnk(), "Archive contains links")
            if not member.isfile():
                continue
            require(name not in files, "Archive contains duplicate file names")
            require(not any(part in (".dart_tool", "tool", "bin", "web", ".cache") for part in path.parts), "Archive contains development assets")
            require(path.suffix not in (".db", ".key", ".pem", ".sqlite"), "Archive contains private or runtime files")
            total += member.size
            require(total <= 100 * 1024 * 1024, "Uncompressed package exceeds the reviewed archive bound")
            files[name] = archive.extractfile(member).read()
    for required in ("pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md", "lib/cosmos_sync.dart"):
        require(required in files, "Published archive lacks " + required)
    local = {str(p.relative_to(PACKAGE)): p.read_bytes() for p in (PACKAGE / "lib").rglob("*.dart")}
    for file in ("pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md"):
        local[file] = (PACKAGE / file).read_bytes()
    for path in (PACKAGE / "doc").rglob("*.md"):
        local[str(path.relative_to(PACKAGE))] = path.read_bytes()
    for name, content in local.items():
        require(files.get(name) == content, "Published content differs from approved source: " + name)
    require({name for name in files if name.startswith("lib/")} == {name for name in local if name.startswith("lib/")}, "Published library file set differs from source")
    for name, content in files.items():
        source = (PACKAGE / name).resolve()
        require(source.is_relative_to(PACKAGE) and source.is_file() and source.read_bytes() == content, "Archive file differs from local reviewed source: " + name)
    return {"archiveSha256": actual, "archiveBytes": len(raw), "uncompressedBytes": total, "verifiedFiles": len(local)}


def resolved_consumer_package(config_file, version, cache_directory):
    config = json.loads(config_file.read_text())
    packages = [p for p in config["packages"] if p["name"] == "cosmos_sync"]
    require(len(packages) == 1, "Resolved consumer must contain exactly one cosmos_sync package")
    parsed = urlparse(packages[0]["rootUri"])
    require(parsed.scheme == "file" and not parsed.netloc, "Consumer package must resolve to a local hosted-cache file")
    root = Path(unquote(parsed.path)).resolve()
    expected = (cache_directory / "hosted/pub.dev" / ("cosmos_sync-" + version)).resolve()
    require(root == expected, "Consumer did not resolve the exact version from its isolated pub.dev cache")
    local = {str(p.relative_to(PACKAGE / "lib")): p.read_bytes() for p in (PACKAGE / "lib").rglob("*.dart")}
    installed = {str(p.relative_to(root / "lib")): p.read_bytes() for p in (root / "lib").rglob("*.dart")}
    require(installed == local, "Installed hosted library differs from the reviewed source")
    return root


FLUTTER_CONSUMER_TEST = """import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic verified scope and deliberately unusable BFF. This verifies local
// installed-package storage/imports; it does not claim live cloud acceptance.
void main() {
  test('published cache commits offline and survives reopen', () async {
    final path = 'published-consumer-${DateTime.now().microsecondsSinceEpoch}';
    HttpSyncTransport transport() => HttpSyncTransport(
      baseUri: Uri.parse('https://unused.invalid'),
      tokenProvider: () async => 'synthetic-unused-token',
    );
    var client = await CosmosSyncClient.open(
      path: path,
      transport: transport(),
      session: const SessionInfo(principalId: 'demo', scopeId: 'demo', permissionVersion: '1'),
    );
    try {
      await client.put('proof', {'text': 'durable offline'});
      expect(client.get('proof')!.hasPendingWrites, isTrue);
      await client.close();
      client = await CosmosSyncClient.open(path: path, transport: transport());
      expect(client.get('proof')!.data!['text'], 'durable offline');
      expect(client.get('proof')!.hasPendingWrites, isTrue);
      await client.delete('proof');
      expect(client.get('proof')!.deleted, isTrue);
      expect(client.list(), isEmpty);
      await client.signOut();
    } finally {
      await client.close();
    }
  });
}
"""

FLUTTER_CONSUMER_MAIN = """import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: ConsumerView()));

class ConsumerView extends StatelessWidget {
  const ConsumerView({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Text('Published SDK query limit: ${LocalQuery(limit: 5).limit}')),
  );
}
"""


def consumer_verify(version):
    dart = os.environ.get("DART") or shutil.which("dart")
    require(dart, "Dart is required for installed-package verification")
    flutter = os.environ.get("FLUTTER") or shutil.which("flutter")
    require(flutter, "Flutter and Chromium are required for installed-package verification")
    with tempfile.TemporaryDirectory(prefix="cosmos-sync-published-consumer-") as directory:
        destination = Path(directory)
        cache_directory = destination / ".pub-cache"
        (destination / "pubspec.yaml").write_text("name: cosmos_sync_release_consumer\npublish_to: none\nenvironment:\n  sdk: ^3.12.0\ndependencies:\n  cosmos_sync: " + version + "\n")
        (destination / "consumer.dart").write_bytes((PACKAGE / "example/cosmos_sync_example.dart").read_bytes())
        environment = dict(os.environ, CI="true", PUB_HOSTED_URL="https://pub.dev", PUB_CACHE=str(cache_directory))
        resolved = subprocess.run([dart, "--suppress-analytics", "pub", "get"], cwd=destination, env=environment, text=True, capture_output=True, timeout=180)
        require(resolved.returncode == 0, "Clean consumer could not resolve the published package")
        resolved_consumer_package(destination / ".dart_tool/package_config.json", version, cache_directory)
        executed = subprocess.run([dart, "--suppress-analytics", "run", "consumer.dart"], cwd=destination, env=environment, text=True, capture_output=True, timeout=180)
        require(executed.returncode == 0 and all(marker in executed.stdout for marker in ("Offline pending: true", "After restart: Saved locally while offline", "Acknowledged version: 1", "Deletion tombstone: true")), "Published native SQLite example did not satisfy its runtime contract")
        application = destination / "flutter_consumer"
        generated = subprocess.run([flutter, "--suppress-analytics", "create", "--no-pub", "--platforms=web", "--project-name", "cosmos_sync_release_flutter_consumer", str(application)], env=environment, text=True, capture_output=True, timeout=180)
        require(generated.returncode == 0, "Could not create an isolated Flutter consumer")
        (application / "pubspec.yaml").write_text("name: cosmos_sync_release_flutter_consumer\npublish_to: none\nenvironment:\n  sdk: ^3.12.0\ndependencies:\n  flutter:\n    sdk: flutter\n  cosmos_sync: " + version + "\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\nflutter:\n  uses-material-design: true\n")
        (application / "lib/main.dart").write_text(FLUTTER_CONSUMER_MAIN)
        (application / "test/widget_test.dart").unlink(missing_ok=True)
        (application / "test/published_cache_test.dart").write_text(FLUTTER_CONSUMER_TEST)
        # The generated lint file otherwise refers to an unrelated dependency.
        (application / "analysis_options.yaml").write_text("analyzer:\n  errors:\n    todo: ignore\n")
        commands = (
            ("Flutter hosted package resolution", ["pub", "get"], 180),
            ("Flutter public imports analysis", ["analyze", "--no-pub", "lib/main.dart", "test/published_cache_test.dart"], 180),
            ("Flutter native SQLite offline/reopen/tombstone runtime", ["test", "--no-pub", "test/published_cache_test.dart"], 300),
            ("Flutter Chromium IndexedDB offline/reopen/tombstone runtime", ["test", "--no-pub", "--platform", "chrome", "test/published_cache_test.dart"], 300),
            ("Flutter release web build", ["build", "web", "--release", "--no-pub"], 600),
        )
        for index, (description, arguments, timeout) in enumerate(commands):
            result = subprocess.run([flutter, "--suppress-analytics", *arguments], cwd=application, env=environment, text=True, capture_output=True, timeout=timeout)
            require(result.returncode == 0, "Published consumer failed: " + description)
            if index == 0:
                resolved_consumer_package(application / ".dart_tool/package_config.json", version, cache_directory)
        return {
            "registryResolution": "exact version from isolated pub.dev cache; installed library bytes match source",
            "dartNative": "SQLite offline/reopen/ACK/tombstone example (demo transport)",
            "flutterNative": "SQLite offline/reopen/tombstone runtime",
            "flutterBrowser": "Chromium IndexedDB offline/reopen/tombstone runtime",
            "flutterImports": "public API analysis and release web build",
            "liveCloudVerified": False,
        }


def pub_verify(version, sha):
    require(SEMVER.fullmatch(version), "Invalid package version")
    require(SHA.fullmatch(sha), "Use the full lowercase SHA of the reviewed published source")
    require(run("git", "rev-parse", "HEAD") == sha, "Checked-out source differs from the published source SHA")
    require(not run("git", "status", "--porcelain"), "Published source verification requires a clean working tree")
    require(metadata()["version"] == version, "Checked-out package version differs from registry version")
    info = json_url("https://pub.dev/api/packages/cosmos_sync/versions/" + version)
    require(info.get("version") == version and info.get("pubspec", {}).get("name") == "cosmos_sync", "Registry metadata differs from expected package")
    archive_url = info.get("archive_url", "")
    parsed = urlparse(archive_url)
    require(parsed.scheme == "https" and parsed.hostname == "pub.dev", "Unexpected registry archive origin")
    with safe_open(archive_url) as response:
        raw = response.read(50 * 1024 * 1024 + 1)
    require(len(raw) <= 50 * 1024 * 1024, "Published archive exceeds the reviewed transfer bound")
    evidence = validate_archive(raw, info.get("archive_sha256"))
    evidence.update({"package": "https://pub.dev/packages/cosmos_sync/versions/" + version, "version": version, "sourceSha": sha})
    evidence["consumer"] = consumer_verify(version)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    before = subparsers.add_parser("preflight")
    before.add_argument("--target", choices=("prepare", "ghcr", "pub"), default="prepare")
    before.add_argument("--sha")
    before.add_argument("--version")
    image = subparsers.add_parser("ghcr")
    image.add_argument("--digest", required=True)
    image.add_argument("--sha", required=True)
    image.add_argument("--version", required=True)
    image.add_argument("--visibility", choices=("private", "public"), required=True)
    package = subparsers.add_parser("pub")
    package.add_argument("--version", required=True)
    package.add_argument("--sha", required=True, help="Full reviewed published source commit SHA; must match the clean checkout")
    for command in (before, image, package):
        command.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "preflight":
            result = preflight(args.target, args.sha, args.version)
        elif args.command == "ghcr":
            result = ghcr_verify(args.digest, args.sha, args.version, args.visibility)
        else:
            result = pub_verify(args.version, args.sha)
        formatted = json.dumps(result, indent=2) + "\n"
        if args.output:
            args.output.write_text(formatted)
        print(formatted, end="")
    except (ReleaseError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        print("Release verification failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
