#!/bin/bash
# run.sh <results-dir> -- offline build from the inputs localized by deps.sh or shipped in a kit.
set -euo pipefail
source "$(dirname "$0")/common.sh"
results=${1:?usage: run.sh <results-dir>}

[ ! -e "$results" ] || [ -z "$(ls -A "$results")" ] || { echo "results dir not empty: $results" >&2; exit 1; }
mkdir -p "$results"

verify_builder
docker load --input "$INPUTS/$BUILDER_ARCHIVE"

# xz comes from the builder image: a kit needs nothing on the host but tar and Docker
if [ -f "$INPUTS/deps.tar.xz" ]; then
    docker run --rm --network none --user "$(id -u):$(id -g)" -v "$(cd "$INPUTS" && pwd):/inputs" \
        --entrypoint tar "$BUILDER_IMAGE" -xJf /inputs/deps.tar.xz -C /inputs
fi
verify_sources

container=$(docker create --network none -e "JDK_MAJOR=$JDK_MAJOR" "$BUILDER_IMAGE")
trap 'docker rm -f "$container" >/dev/null' EXIT

for f in $(source_tars); do docker cp -q "$INPUTS/$f" "$container:/inputs/$f"; done
for f in build.sh versions.env versions; do docker cp -q "$ROOT/$f" "$container:/opt/$f"; done

rc=0
docker start --attach "$container" || rc=$?
docker cp -q "$container:/results/." "$results"
exit $rc
