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

verify_builder() {
    is_verified "$INPUTS/$BUILDER_ARCHIVE" "$(awk -v n="$BUILDER_ARCHIVE" '$1 == n {print $2}' "$LOCK")" ||
        { echo "input not localized: $BUILDER_ARCHIVE, run deps.sh" >&2; exit 1; }
}

verify_sources() {
    while read -r name _ sha _; do
        [ "$name" = "$BUILDER_ARCHIVE" ] && continue
        is_verified "$INPUTS/$name.tar" "$sha" || { echo "input not localized: $name, run deps.sh" >&2; exit 1; }
    done < "$LOCK"
}

source_tars() {
    awk -v n="$BUILDER_ARCHIVE" '$1 != n {print $1 ".tar"}' "$LOCK"
}
