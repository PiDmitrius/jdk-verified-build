#!/bin/bash
# deps.sh -- online stage: localize everything run.sh needs into $INPUTS.
# Lock line: <name> <sha256 of published .tar.gz> <sha256 of unpacked .tar> <url>.
# A file already present with the right SHA-256 is kept; a missing one is downloaded,
# verified and unpacked. A "-" in a lock line is pinned to what was obtained.
# The builder image is built from Dockerfile unless $INPUTS already has it.
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$INPUTS"

settle() {  # <file> <lock sha256> <lock name>
    if [ "$2" != - ]; then
        is_verified "$1" "$2" || { echo "SHA-256 mismatch: $3" >&2; exit 1; }
    else
        local got
        got=$(sha256sum "$1" | cut -d' ' -f1)
        sed -i "/^$3 /s/ - / $got /" "$LOCK"
        echo "pinned: $3 $got"
    fi
}

while read -r name gz tar url; do
    file="$INPUTS/$name.tar"
    if [ "$tar" != - ] && is_verified "$file" "$tar"; then echo "local: $name"; continue; fi
    echo "fetch: $name"
    curl --fail --location --retry 3 --output "$file.gz.part" "$url"
    settle "$file.gz.part" "$gz" "$name"
    gzip -dc < "$file.gz.part" > "$file.part"
    rm "$file.gz.part"
    settle "$file.part" "$tar" "$name"
    mv "$file.part" "$file"
done < "$LOCK"

if [ -f "$INPUTS/$BUILDER_ARCHIVE" ]; then
    echo "local: $BUILDER_ARCHIVE"
else
    echo "build: $BUILDER_ARCHIVE"
    docker build --no-cache --provenance=false --build-arg "JDK_MAJOR=$JDK_MAJOR" -t "$BUILDER_IMAGE" "$ROOT"
    docker save "$BUILDER_IMAGE" | gzip -n > "$INPUTS/$BUILDER_ARCHIVE.part"
    mv "$INPUTS/$BUILDER_ARCHIVE.part" "$INPUTS/$BUILDER_ARCHIVE"
fi
echo "all inputs local: $INPUTS"
