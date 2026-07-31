#!/bin/zsh

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly default_sparkle_bin="${repository_root:h}/flick-app/Tuist/.build/artifacts/sparkle/Sparkle/bin"
readonly download_url_prefix="https://flickplanner.github.io/flick-releases/updates/"
readonly product_link="https://www.flickplanner.com"
readonly expected_bundle_id="com.pawtask"
readonly expected_team_id="97247339Z3"
readonly recovery_build=3
readonly program_name="${0:t}"

dmg_path=""
sparkle_bin="$default_sparkle_bin"
sparkle_account="flick-planner"

usage() {
    echo "Usage: $program_name --dmg /path/to/Flick-version.dmg [--sparkle-bin /path/to/Sparkle/bin]"
    echo "          [--account flick-planner]"
}

while (( $# > 0 )); do
    case "$1" in
        --dmg)
            dmg_path="$2"
            shift 2
            ;;
        --sparkle-bin)
            sparkle_bin="$2"
            shift 2
            ;;
        --account)
            sparkle_account="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$dmg_path" || ! -f "$dmg_path" ]]; then
    echo "error: --dmg must point to an existing disk image." >&2
    exit 2
fi

for sparkle_tool in generate_appcast generate_keys sign_update; do
    if [[ ! -x "$sparkle_bin/$sparkle_tool" ]]; then
        echo "error: Missing executable Sparkle tool: $sparkle_bin/$sparkle_tool" >&2
        exit 2
    fi
done

mount_directory="$(mktemp -d /tmp/flick-update-mount.XXXXXX)"
generation_directory="$(mktemp -d /tmp/flick-update-generation.XXXXXX)"
mounted=false

cleanup() {
    if $mounted; then
        hdiutil detach "$mount_directory" >/dev/null 2>&1 || true
    fi
    rmdir "$mount_directory" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Verifying disk image integrity and notarization..."
hdiutil verify "$dmg_path"
codesign --verify --strict --verbose=2 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
xcrun stapler validate "$dmg_path"

hdiutil attach -readonly -nobrowse -mountpoint "$mount_directory" "$dmg_path" >/dev/null
mounted=true

app_path="$(find "$mount_directory" -maxdepth 2 -type d -name '*.app' -print -quit)"
if [[ -z "$app_path" ]]; then
    echo "error: The disk image does not contain an app bundle." >&2
    exit 1
fi

info_plist="$app_path/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
marketing_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")"
feed_url="$(plutil -extract SUFeedURL raw -o - "$info_plist")"
embedded_public_key="$(plutil -extract SUPublicEDKey raw -o - "$info_plist")"
keychain_public_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p)"

if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
    echo "error: Expected bundle ID $expected_bundle_id, found $bundle_id." >&2
    exit 1
fi
if [[ "$build_version" != <-> || "$build_version" -lt "$recovery_build" ]]; then
    echo "error: CFBundleVersion must be an integer greater than or equal to $recovery_build." >&2
    exit 1
fi
if [[ -z "$marketing_version" || -z "$minimum_system" ]]; then
    echo "error: The app must declare marketing and minimum-system versions." >&2
    exit 1
fi
if [[ "$feed_url" != "${download_url_prefix}appcast.xml" ]]; then
    echo "error: Unexpected SUFeedURL: $feed_url" >&2
    exit 1
fi
if [[ "$embedded_public_key" != "$keychain_public_key" ]]; then
    echo "error: The app's SUPublicEDKey does not match Sparkle account $sparkle_account." >&2
    exit 1
fi

for boolean_key in \
    SUAllowsAutomaticUpdates \
    SUAutomaticallyUpdate \
    SUEnableAutomaticChecks \
    SUEnableInstallerLauncherService \
    SURequireSignedFeed \
    SUVerifyUpdateBeforeExtraction; do
    if [[ "$(plutil -extract "$boolean_key" raw -o - "$info_plist")" != "true" ]]; then
        echo "error: $boolean_key must be enabled." >&2
        exit 1
    fi
done

echo "Verifying app signature, entitlements, and notarization..."
codesign --verify --deep --strict --verbose=4 "$app_path"
team_id="$(codesign -dvv "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$team_id" != "$expected_team_id" ]]; then
    echo "error: Expected Developer ID team $expected_team_id, found $team_id." >&2
    exit 1
fi

entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null)"
for mach_service in "${expected_bundle_id}-spks" "${expected_bundle_id}-spki"; do
    if [[ "$entitlements" != *"$mach_service"* ]]; then
        echo "error: Missing Sparkle Mach lookup entitlement $mach_service." >&2
        exit 1
    fi
done

spctl --assess --type execute --verbose=4 "$app_path"
xcrun stapler validate "$app_path"

hdiutil detach "$mount_directory" >/dev/null
mounted=false

artifact_name="Flick-${marketing_version}.dmg"
ditto "$dmg_path" "$generation_directory/$artifact_name"

echo "Generating and signing appcast for Flick $marketing_version (build $build_version)..."
generation_arguments=(
    --account "$sparkle_account"
    --download-url-prefix "$download_url_prefix"
    --link "$product_link"
    --maximum-versions 1
    --maximum-deltas 0
    -o "$generation_directory/appcast.xml"
)
if [[ "$build_version" -eq "$recovery_build" ]]; then
    generation_arguments+=(--major-version "$recovery_build")
fi
"$sparkle_bin/generate_appcast" "${generation_arguments[@]}" "$generation_directory"
"$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$generation_directory/appcast.xml"

archive_signature="$(
    python3 - \
        "$generation_directory/appcast.xml" \
        "$build_version" \
        "$marketing_version" \
        "$minimum_system" <<'PYTHON'
import sys
import xml.etree.ElementTree as ElementTree

sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ElementTree.parse(sys.argv[1]).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("Generated appcast has no update item.")

expected_values = {
    "version": sys.argv[2],
    "shortVersionString": sys.argv[3],
    "minimumSystemVersion": sys.argv[4],
}
for element_name, expected_value in expected_values.items():
    actual_value = item.findtext(f"{sparkle}{element_name}", "").strip()
    if actual_value != expected_value:
        raise SystemExit(
            f"Generated {element_name} {actual_value!r} does not match the app's {expected_value!r}."
        )

enclosure = root.find("./channel/item/enclosure")
sparkle_signature = f"{sparkle}edSignature"
if enclosure is None or sparkle_signature not in enclosure.attrib:
    raise SystemExit("Generated appcast has no signed enclosure.")
print(enclosure.attrib[sparkle_signature])
PYTHON
)"
"$sparkle_bin/sign_update" \
    --account "$sparkle_account" \
    --verify "$generation_directory/$artifact_name" \
    "$archive_signature"
"$repository_root/Script/validate_appcast.py" \
    --appcast "$generation_directory/appcast.xml" \
    --updates-directory "$generation_directory"

mkdir -p "$repository_root/old_updates"
for existing_dmg in "$repository_root"/updates/*.dmg(N); do
    mv "$existing_dmg" "$repository_root/old_updates/"
done

ditto "$generation_directory/$artifact_name" "$repository_root/updates/$artifact_name"
ditto "$generation_directory/appcast.xml" "$repository_root/updates/appcast.xml"
"$repository_root/Script/validate_appcast.py"

echo
echo "Prepared updates/$artifact_name and updates/appcast.xml."
echo "Review the diff, commit, push, wait for GitHub Pages, then run Script/verify_live_update.sh."
echo "Temporary generation files remain at $generation_directory for inspection."
