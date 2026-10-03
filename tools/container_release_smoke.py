#!/usr/bin/env python3
"""Build and verify the real multi-architecture OCI release bundle without pushing."""

import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import uuid

import release_verify as release


def verify_bundle(path, sha, version):
    with tarfile.open(path) as archive:
        def blob(digest):
            release.require(release.DIGEST.fullmatch(digest), "Invalid OCI blob digest")
            data = archive.extractfile("blobs/sha256/" + digest[7:]).read()
            release.require(hashlib.sha256(data).hexdigest() == digest[7:], "OCI blob checksum mismatch")
            return json.loads(data)

        index = json.load(archive.extractfile("index.json"))
        for _ in range(3):
            entries = index.get("manifests", [])
            if len(entries) == 1 and not entries[0].get("platform"):
                index = blob(entries[0]["digest"])
            else:
                break
        release.validate_manifest(index)
        platforms = []
        for entry in index["manifests"]:
            if entry.get("platform", {}).get("os") != "linux":
                continue
            architecture = entry["platform"]["architecture"]
            manifest = blob(entry["digest"])
            config = blob(manifest["config"]["digest"])
            release.validate_image(config, sha, version, architecture)
            attached = next(m for m in index["manifests"] if m.get("annotations", {}).get("vnd.docker.reference.digest") == entry["digest"])
            predicates = set()
            for layer in blob(attached["digest"])["layers"]:
                statement = blob(layer["digest"])
                subject_digests = [s.get("digest", {}).get("sha256") for s in statement.get("subject", [])]
                release.require(entry["digest"][7:] in subject_digests, "Attestation subject differs from platform manifest: " + str(subject_digests) + "; expected " + entry["digest"] + "; predicate " + statement["predicateType"])
                predicates.add(statement["predicateType"])
            release.require(any(p.startswith("https://slsa.dev/provenance/") for p in predicates), "Missing SLSA provenance")
            release.require("https://spdx.dev/Document" in predicates, "Missing SPDX SBOM")
            platforms.append("linux/" + architecture)
        return {"result": "PASS", "platforms": platforms, "sourceSha": sha, "version": version, "imageBytes": path.stat().st_size, "provenance": "BuildKit (not signed GitHub)", "sbom": "SPDX", "published": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder", help="Existing docker-container builder; otherwise creates and cleans its own")
    args = parser.parse_args()
    owned_builder = None
    try:
        sha = release.run("git", "rev-parse", "HEAD")
        version = release.metadata()["version"]
        with tempfile.TemporaryDirectory(prefix="cosmos-sync-oci-smoke-") as directory:
            bundle = Path(directory) / "release.tar"
            labels = {"source": release.SOURCE, "revision": sha, "version": version}
            builder = args.builder
            if builder is None:
                owned_builder = "cosmos-sync-release-" + uuid.uuid4().hex[:12]
                subprocess.run(["docker", "buildx", "create", "--name", owned_builder, "--driver", "docker-container"], check=True, timeout=60, stdout=sys.stderr)
                builder = owned_builder
            command = ["docker", "buildx", "build", "--builder", builder, "--platform=linux/amd64,linux/arm64", "--provenance=mode=min", "--sbom=true", "--output=type=oci,name=cosmos-sync-bff:check,dest=" + str(bundle)]
            for name, value in labels.items():
                command.extend(["--label", "org.opencontainers.image." + name + "=" + value])
            command.append("bff")
            subprocess.run(command, cwd=release.ROOT, check=True, timeout=600, stdout=sys.stderr)
            result = verify_bundle(bundle, sha, version)
            result["sourceTreeDirty"] = bool(release.run("git", "status", "--porcelain"))
            print(json.dumps(result, indent=2))
        return 0
    except (release.ReleaseError, subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        print("Container release smoke failed: " + str(error), file=sys.stderr)
        return 1
    finally:
        if owned_builder:
            cleanup = subprocess.run(["docker", "buildx", "rm", owned_builder], timeout=60, stdout=sys.stderr)
            if cleanup.returncode:
                print("Remove only owned builder if cleanup failed: " + owned_builder, file=sys.stderr)
                return 1


if __name__ == "__main__":
    sys.exit(main())
