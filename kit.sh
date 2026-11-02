#!/bin/bash
# kit.sh <output.tar> -- self-contained offline kit: builder image, sources and boot JDKs
# compressed with one dictionary, recipe, expected hashes.
set -euo pipefail
source "$(dirname "$0")/common.sh"
output=${1:?usage: kit.sh <output.tar>}

load_builder
verify_sources
mkdir -p "$ROOT/dist" "$(dirname "$output")"

tar -C "$INPUTS" --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=a+r,u+w \
    -cf - $(source_tars) | xz -T1 --lzma2=preset=6,dict=1GiB,mf=hc4 > "$ROOT/dist/deps.tar.xz"

cp "$INPUTS/$BUILDER_ARCHIVE" "$ROOT/dist/$BUILDER_ARCHIVE"
tar -C "$ROOT" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=a+rX,u+w \
    --transform "s,^dist/,inputs/,;s,^,jdk-verified-$JDK_MAJOR/," -cf "$output" \
    README.md LICENSE Dockerfile .dockerignore common.sh deps.sh run.sh verify.sh kit.sh build.sh \
    versions.env "versions/$JDK_MAJOR.env" "versions/$JDK_MAJOR.lock" "versions/$JDK_MAJOR.packages" \
    "expected/$JDK_MAJOR" "dist/$BUILDER_ARCHIVE" dist/deps.tar.xz
rm "$ROOT/dist/$BUILDER_ARCHIVE"
sha256sum "$output"
