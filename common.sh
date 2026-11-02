# common.sh -- shared by deps.sh, run.sh and kit.sh
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JDK_MAJOR=${JDK_MAJOR:-25}
LOCK="$ROOT/versions/$JDK_MAJOR.lock"
INPUTS=${INPUTS:-$ROOT/inputs}
BUILDER_ARCHIVE=docker-builder.tar.gz
BUILDER_IMAGE="jdk-verified-builder:$JDK_MAJOR"

is_verified() {  # <file> <sha256>
    [ -f "$1" ] && echo "$2  $1" | sha256sum -c --status -
}

verify_sources() {
    while read -r name _ sha _; do
        is_verified "$INPUTS/$name.tar" "$sha" || { echo "input not localized: $name, run deps.sh" >&2; exit 1; }
    done < "$LOCK"
}

source_tars() {
    awk '{print $1 ".tar"}' "$LOCK"
}

# The image archive is not bit-for-bit reproducible, its identity is the package list
load_builder() {
    [ -f "$INPUTS/$BUILDER_ARCHIVE" ] || { echo "builder not localized, run deps.sh" >&2; exit 1; }
    docker load --input "$INPUTS/$BUILDER_ARCHIVE"
    docker run --rm --network none --entrypoint dpkg-query "$BUILDER_IMAGE" -W -f '${binary:Package}=${Version}\n' |
        LC_ALL=C sort | diff "$ROOT/versions/$JDK_MAJOR.packages" - ||
        { echo "builder packages differ from versions/$JDK_MAJOR.packages" >&2; exit 1; }
}
