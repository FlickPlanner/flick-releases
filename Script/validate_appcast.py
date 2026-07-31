#!/usr/bin/env python3
"""Validate Flick's signed Sparkle appcast and locally hosted update artifacts."""

from __future__ import annotations

import argparse
import base64
import binascii
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ElementTree
from email.utils import parsedate_to_datetime
from pathlib import Path


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE_ATTRIBUTE = f"{{{SPARKLE_NAMESPACE}}}"
SIGNATURE_PATTERN = re.compile(rb"edSignature:\s*([A-Za-z0-9+/=]+)")
SYSTEM_VERSION_PATTERN = re.compile(r"^\d+\.\d+(?:\.\d+)?$")
DOWNLOAD_URL_PREFIX = "https://flickplanner.github.io/flick-releases/updates/"
RECOVERY_BUILD = 3
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def fail(message: str) -> None:
    """Report a validation failure without producing a traceback."""
    raise ValueError(message)


def validate_feed_signature(appcast_data: bytes) -> None:
    """Require a plausibly encoded Sparkle signed-feed header."""
    match = SIGNATURE_PATTERN.search(appcast_data)
    if match is None:
        fail("The appcast is not signed with a feed-level EdDSA signature.")

    try:
        signature = base64.b64decode(match.group(1), validate=True)
    except (ValueError, binascii.Error) as error:
        fail(f"The feed-level EdDSA signature is not valid base64: {error}")

    if len(signature) != 64:
        fail("The feed-level EdDSA signature must decode to 64 bytes.")


def required_text(item: ElementTree.Element, child_name: str) -> str:
    """Return required, trimmed text from a Sparkle-namespaced item child."""
    child = item.find(f"{SPARKLE_ATTRIBUTE}{child_name}")
    if child is None or child.text is None or not child.text.strip():
        fail(f"An appcast item is missing sparkle:{child_name}.")
    return child.text.strip()


def validate_item(item: ElementTree.Element, updates_directory: Path) -> tuple[int, str]:
    """Validate one appcast item and return its build number and artifact name."""
    build_text = required_text(item, "version")
    short_version = required_text(item, "shortVersionString")
    minimum_system_text = required_text(item, "minimumSystemVersion")

    if not build_text.isdecimal() or int(build_text) <= 0:
        fail(f"CFBundleVersion must be a positive integer, found {build_text!r}.")
    if int(build_text) < RECOVERY_BUILD:
        fail(f"Build {build_text} predates the supported recovery build {RECOVERY_BUILD}.")

    if not SYSTEM_VERSION_PATTERN.fullmatch(minimum_system_text):
        fail(f"Invalid minimum system version for build {build_text}: {minimum_system_text!r}.")

    published_date = item.findtext("pubDate", "").strip()
    if not published_date:
        fail(f"Build {build_text} has no pubDate.")
    try:
        parsed_date = parsedate_to_datetime(published_date)
    except (TypeError, ValueError) as error:
        fail(f"Build {build_text} has an invalid pubDate: {error}")
    if parsed_date.tzinfo is None:
        fail(f"Build {build_text} pubDate must include a time zone.")
    declared_weekday = published_date.partition(",")[0]
    expected_weekday = WEEKDAYS[parsed_date.weekday()]
    if declared_weekday != expected_weekday:
        fail(
            f"Build {build_text} pubDate declares {declared_weekday!r}, "
            f"but its calendar date is {expected_weekday}."
        )

    minimum_autoupdate = item.find(f"{SPARKLE_ATTRIBUTE}minimumAutoupdateVersion")
    if int(build_text) == RECOVERY_BUILD:
        minimum_autoupdate_text = (
            minimum_autoupdate.text.strip()
            if minimum_autoupdate is not None and minimum_autoupdate.text is not None
            else ""
        )
        if minimum_autoupdate_text != str(RECOVERY_BUILD):
            fail(
                f"Recovery build {RECOVERY_BUILD} must declare "
                f"sparkle:minimumAutoupdateVersion as {RECOVERY_BUILD}."
            )

    enclosure = item.find("enclosure")
    if enclosure is None:
        fail(f"Build {build_text} ({short_version}) has no enclosure.")

    signature = enclosure.get(f"{SPARKLE_ATTRIBUTE}edSignature", "")
    if not signature:
        fail(f"Build {build_text} has no sparkle:edSignature.")

    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (ValueError, binascii.Error) as error:
        fail(f"Build {build_text} has an invalid EdDSA signature: {error}")

    if len(decoded_signature) != 64:
        fail(f"Build {build_text} has an EdDSA signature that is not 64 bytes.")

    url = enclosure.get("url", "")
    parsed_url = urllib.parse.urlparse(url)
    if parsed_url.scheme != "https" or not parsed_url.netloc:
        fail(f"Build {build_text} enclosure must use an absolute HTTPS URL.")
    if not url.startswith(DOWNLOAD_URL_PREFIX):
        fail(f"Build {build_text} enclosure must use the Flick GitHub Pages update directory.")

    artifact_name = Path(urllib.parse.unquote(parsed_url.path)).name
    artifact_path = updates_directory / artifact_name
    if not artifact_path.is_file():
        fail(f"Build {build_text} references missing local artifact {artifact_name!r}.")

    length_text = enclosure.get("length", "")
    if not length_text.isdecimal() or int(length_text) <= 0:
        fail(f"Build {build_text} has an invalid enclosure length.")

    actual_length = artifact_path.stat().st_size
    if actual_length != int(length_text):
        fail(
            f"Build {build_text} declares {length_text} bytes, "
            f"but {artifact_name} is {actual_length} bytes."
        )

    if enclosure.get("type") != "application/octet-stream":
        fail(f"Build {build_text} must use application/octet-stream.")

    return int(build_text), artifact_name


def validate_appcast(appcast_path: Path, updates_directory: Path) -> None:
    """Validate the signed feed, its ordering, and all referenced local artifacts."""
    appcast_data = appcast_path.read_bytes()
    validate_feed_signature(appcast_data)

    try:
        root = ElementTree.fromstring(appcast_data)
    except ElementTree.ParseError as error:
        fail(f"The appcast XML is malformed: {error}")

    channel = root.find("channel")
    if channel is None:
        fail("The appcast has no channel element.")

    items = channel.findall("item")
    if len(items) > 1:
        fail("The published appcast must contain only the current update item.")

    validated_items = [validate_item(item, updates_directory) for item in items]
    builds = [build for build, _ in validated_items]
    if len(builds) != len(set(builds)):
        fail("The appcast contains duplicate bundle build numbers.")
    if builds != sorted(builds, reverse=True):
        fail("Appcast items must be ordered by descending bundle build number.")

    referenced_artifacts = {artifact for _, artifact in validated_items}
    published_artifacts = {artifact.name for artifact in updates_directory.glob("*.dmg")}
    if published_artifacts != referenced_artifacts:
        fail("The updates directory must contain only DMGs referenced by the current appcast.")
    if any(updates_directory.rglob(".DS_Store")):
        fail("The updates directory contains disallowed .DS_Store metadata.")

    if builds:
        print(f"Validated {len(builds)} update item(s); newest build is {builds[0]}.")
    else:
        print("Validated signed holding feed with no published update items.")


def parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""
    repository_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--appcast",
        type=Path,
        default=repository_root / "updates" / "appcast.xml",
        help="Path to the appcast XML file.",
    )
    parser.add_argument(
        "--updates-directory",
        type=Path,
        default=repository_root / "updates",
        help="Directory containing the appcast's DMG artifacts.",
    )
    return parser.parse_args()


def main() -> int:
    """Run appcast validation and return a shell-friendly status."""
    arguments = parse_arguments()
    try:
        validate_appcast(arguments.appcast, arguments.updates_directory)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
