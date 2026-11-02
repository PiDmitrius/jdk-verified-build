#!/bin/bash
# deps.sh -- localize every input listed in versions/<major>.lock into $INPUTS.
# Lock line: <name> <sha256 of published .tar.gz> <sha256 of unpacked .tar> <url>;
# the builder archive is kept packed, and url "-" builds it from Dockerfile.
# A file already present with the right SHA-256 is kept; a missing one is downloaded,
# verified and unpacked. A "-" in a lock line is pinned to what was obtained.
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
    if [ "$name" = "$BUILDER_ARCHIVE" ]; then
        file="$INPUTS/$name"
        if [ "$gz" != - ] && is_verified "$file" "$gz"; then echo "local: $name"; continue; fi
        if [ "$url" != - ]; then
            echo "fetch: $name"
            curl --fail --location --retry 3 --output "$file.part" "$url"
        else
            echo "build: $name"
            docker build --provenance=false --build-arg "JDK_MAJOR=$JDK_MAJOR" -t "$BUILDER_IMAGE" "$ROOT"
            docker save "$BUILDER_IMAGE" | gzip -n > "$file.part"
        fi
        settle "$file.part" "$gz" "$name"
        mv "$file.part" "$file"
        continue
    fi
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
echo "all inputs local: $INPUTS"
