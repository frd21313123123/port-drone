#!/usr/bin/env python3
"""Assign updater-compatible CI versions and publish complete GitHub releases."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def version_key(version):
    """Match updater.gd's numeric comparison, including trailing zeroes."""
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError(f"Expected a dotted numeric version, got {version!r}")
    parts = [int(part) for part in version.split(".")]
    if any(part > 2**63 - 1 for part in parts):
        raise ValueError("Version components must fit Godot's signed 64-bit integers")
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def select_version(base, event, ref, run_number, run_attempt, requested=""):
    if event not in ("push", "pull_request", "workflow_dispatch"):
        raise ValueError(f"Unsupported workflow event: {event}")
    version_key(base)
    if event == "push" and ref.startswith("refs/tags/v"):
        version = ref.removeprefix("refs/tags/v")
    elif event == "workflow_dispatch" and requested:
        version = requested
    else:
        if not (re.fullmatch(r"[1-9][0-9]*", run_number)
                and re.fullmatch(r"[1-9][0-9]*", run_attempt)):
            raise ValueError("GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT must be positive integers")
        version = f"{base}.{run_number}.{run_attempt}"
    version_key(version)
    return version, event != "pull_request"


def gh(*args):
    return subprocess.run(["gh", *args], check=True, text=True, stdout=subprocess.PIPE).stdout


def release_assets(dist):
    """Reject incomplete/corrupt artifacts before making any GitHub changes."""
    libraries = list(dist.glob("DroneFlames-libs-r[0-9]*.zip"))
    if len(libraries) != 1:
        raise ValueError("Expected exactly one native-libraries ZIP")
    assets = [dist / "DroneFlames.exe", libraries[0], dist / "SHA256SUMS.txt"]
    checksums = {}
    for line in assets[-1].read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in checksums:
            raise ValueError("Invalid SHA256SUMS.txt")
        checksums[match[2]] = match[1]
    if set(checksums) != {asset.name for asset in assets[:-1]}:
        raise ValueError("SHA256SUMS.txt must cover exactly the executable and libraries")
    for asset in assets[:-1]:
        digest = hashlib.sha256()
        with asset.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != checksums[asset.name]:
            raise ValueError(f"Checksum mismatch: {asset.name}")
    return assets


def publish(version, repo, commit, dist):
    key = version_key(version)
    assets = release_assets(dist)
    tag = f"v{version}"
    # One JSON object per line works across all pages and older gh versions.
    releases = [json.loads(line) for line in gh(
        "api", "--paginate", f"repos/{repo}/releases?per_page=100", "--jq",
        ".[] | {tag_name, draft, prerelease, target_commitish} | @json",
    ).splitlines() if line]
    existing = next((r for r in releases if r["tag_name"] == tag), None)
    if existing:
        if not existing["draft"]:
            raise ValueError(f"{tag} is already published; use a new version instead of replacing it")
        if existing["target_commitish"] != commit:
            raise ValueError(f"Draft {tag} belongs to a different commit")
    latest = True
    for release in releases:
        if release["draft"] or release["prerelease"]:
            continue
        try:
            other = version_key(release["tag_name"].removeprefix("v"))
        except ValueError:
            continue
        if other >= key:
            latest = False
    if not existing:
        notes = (f"Автоматическая сборка {version}.\n"
                 "Игра предложит обновление при следующем запуске.\n\n"
                 f"Commit: {commit}")
        gh("release", "create", tag, "--repo", repo, "--draft", "--latest=false",
           "--target", commit, "--title", f"DroneFlames PC v{version}", "--notes", notes)
    # Only drafts may have assets replaced. They remain invisible to the updater
    # if an upload fails; retrying the release job can finish the same draft.
    gh("release", "upload", tag, *(str(asset) for asset in assets),
       "--repo", repo, "--clobber")
    gh("release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease=false",
       f"--latest={str(latest).lower()}")
    print(f"Published https://github.com/{repo}/releases/tag/{tag} (latest={latest})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version")
    release = commands.add_parser("publish")
    release.add_argument("--version", required=True)
    release.add_argument("--repo", required=True)
    release.add_argument("--commit", required=True)
    release.add_argument("--dist", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if args.command == "version":
        cfg = configparser.ConfigParser()
        cfg.read(ROOT / "game/pc/version.cfg")
        version, should_release = select_version(
            cfg["pc"]["version"].strip('"'), os.environ["GITHUB_EVENT_NAME"],
            os.environ["GITHUB_REF"], os.environ["GITHUB_RUN_NUMBER"],
            os.environ["GITHUB_RUN_ATTEMPT"], os.environ.get("RELEASE_VERSION", ""),
        )
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"version={version}\nrelease={str(should_release).lower()}\n")
        print(f"Build version: {version}; publish: {should_release}")
    else:
        publish(args.version, args.repo, args.commit, args.dist.resolve())


if __name__ == "__main__":
    main()
