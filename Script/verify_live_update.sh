#!/bin/zsh

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly appcast_url="https://flickplanner.github.io/flick-releases/updates/appcast.xml"
readonly local_appcast="$repository_root/updates/appcast.xml"

temporary_appcast="$(mktemp /tmp/flick-live-appcast.XXXXXX.xml)"

cleanup() {
    rm -f -- "$temporary_appcast"
}
trap cleanup EXIT

curl --fail --silent --show-error --location "$appcast_url" --output "$temporary_appcast"

content_type="$(
    curl --fail --silent --show-error --head "$appcast_url" \
        | tr -d '\r' \
        | sed -n 's/^[Cc]ontent-[Tt]ype: //p'
)"
if [[ "$content_type" != application/xml* && "$content_type" != text/xml* ]]; then
    echo "error: Unexpected appcast Content-Type: $content_type" >&2
    exit 1
fi

"$repository_root/Script/validate_appcast.py"
if ! cmp -s "$local_appcast" "$temporary_appcast"; then
    echo "error: The live appcast does not match the validated local appcast." >&2
    exit 1
fi

python3 - "$temporary_appcast" <<'PYTHON'
import sys
import urllib.request
import xml.etree.ElementTree as ElementTree

sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ElementTree.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
if not items:
    print("Live holding feed is reachable and has no update items.")
    raise SystemExit(0)

for item in items:
    build = item.findtext(f"{sparkle}version")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit(f"Build {build} has no enclosure.")
    url = enclosure.attrib["url"]
    expected_length = int(enclosure.attrib["length"])
    request = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise SystemExit(f"Build {build} returned HTTP {response.status}.")
        actual_length = int(response.headers["Content-Length"])
        if actual_length != expected_length:
            raise SystemExit(
                f"Build {build} declares {expected_length} bytes but live response has {actual_length}."
            )
        if response.headers.get_content_type() != "application/octet-stream":
            raise SystemExit(f"Build {build} has unexpected Content-Type.")
    print(f"Validated live build {build}: {url}")
PYTHON
