#!/bin/bash
# build.sh -- build, normalize, verify, package as .deb
set -eo pipefail

source /opt/versions.env

export SOURCE_DATE_EPOCH
BOOT=/opt/boot

# ONE_VENDOR=<suffix> builds with one boot JDK; expected/<major> then stands for the comparison
if [ -n "${ONE_VENDOR:-}" ]; then
    for v in "${VENDORS[@]}"; do [ "${v##*-}" = "$ONE_VENDOR" ] && VENDORS=("$v") && break; done
    [ "${#VENDORS[@]}" -eq 1 ] || { echo "unknown vendor: $ONE_VENDOR" >&2; exit 1; }
fi

SRC=/src/jdk
RESULTS=/results
mkdir -p "$RESULTS"

# -- Unpack inputs; everything below runs without network --

mkdir -p "$SRC"
tar -xf /inputs/src-jdk.tar -C "$SRC" --strip-components=1
for v in "${VENDORS[@]}"; do
    name="${v##*-}"
    mkdir -p "$BOOT/$name"
    tar -xf "/inputs/tool-jdk-$name.tar" -C "$BOOT/$name" --strip-components=1
done

echo "OpenJDK ${JDK_MAJOR} Verified Build | ${#VENDORS[@]} vendors | ${JDK_TAG}"
echo ""

# -- Normalization: remove boot JDK traces from artifacts --

normalize_jar() {
    local jar="$1"
    local tmp
    tmp=$(mktemp -d)
    cd "$tmp"
    unzip -q -o "$jar"
    [ -f META-INF/MANIFEST.MF ] && \
        sed -i 's/^Created-By:.*/Created-By: OpenJDK/' META-INF/MANIFEST.MF
    find . -exec touch -d @${SOURCE_DATE_EPOCH} {} + 2>/dev/null || true
    rm -f "$jar"
    find . -type f | sort | zip -X -q "$jar" -@
    cd /
    rm -rf "$tmp"
}

normalize_jmod() {
    local jmod="$1"
    local tmp
    tmp=$(mktemp -d)
    cd "$tmp"

    # .jmod = 4-byte magic (JM\x01\x00) + zip
    dd if="$jmod" bs=1 count=4 of=header.bin 2>/dev/null
    dd if="$jmod" bs=1 skip=4 of=body.zip 2>/dev/null

    # normalize jars inside
    unzip -q -o body.zip "lib/*.jar" 2>/dev/null || [ $? -eq 11 ]  # 11: no matches
    find . -name "*.jar" -path "*/lib/*" | while read -r inner; do
        normalize_jar "$tmp/$inner"
        cd "$tmp"
        zip -X -q body.zip "$inner"
    done

    # repack zip for stable metadata
    local repack
    repack=$(mktemp -d)
    cd "$repack"
    unzip -q -o "$tmp/body.zip"
    find . -exec touch -d @${SOURCE_DATE_EPOCH} {} + 2>/dev/null || true
    find . -type f | sort | zip -X -q "$tmp/repacked.zip" -@
    rm -rf "$repack"

    cd "$tmp"
    cat header.bin repacked.zip > "$jmod"
    cd /
    rm -rf "$tmp"
}

normalize_image() {
    local image="$1"
    find "$image" -name "*.jar" | while read -r jar; do
        normalize_jar "$jar"
    done
    find "$image/jmods" -name "*.jmod" | while read -r jmod; do
        normalize_jmod "$jmod"
    done
}

# -- Build one vendor: compile, normalize, hash, cleanup --

build_vendor() {
    local vendor_id="$1"
    local name="${vendor_id##*-}"
    local build_dir="$SRC/build/build-$name"
    local image="$build_dir/images/jdk"

    echo "-- $vendor_id --"
    export JAVA_HOME="$BOOT/$name"
    "$JAVA_HOME/bin/java" -version 2>&1 | sed -n 1p

    cd "$SRC"
    rm -rf "$build_dir"

    bash configure \
        --with-boot-jdk="$JAVA_HOME" \
        --with-conf-name="build-$name" \
        --with-native-debug-symbols=none \
        --with-vendor-name="$VENDOR_NAME" \
        --with-vendor-url="$VENDOR_URL" \
        --with-version-pre= \
        --with-version-opt= \
        --disable-warnings-as-errors \
        2>&1 | tail -3

    make CONF="build-$name" images 2>&1 | tail -3
    echo "  build ok"

    normalize_image "$image"
    echo "  normalized"

    # hash all files in jdk image (use subshell to avoid cd side effects)
    (cd "$image" && find . -type f | sort | xargs sha256sum) > "$RESULTS/hashes-$name.txt"
    (cd "$image" && find . -type f \( -name "*.so" -o -name "java" -o -name "javac" \) \
        | sort | xargs sha256sum) > "$RESULTS/native-$name.txt" 2>/dev/null || true
    echo "  $(wc -l < "$RESULTS/hashes-$name.txt") files hashed"

    # cleanup: free disk for next vendor
    rm -rf "$build_dir"
    echo ""
}

# -- Package one build as .deb (only called for final verified build) --

package_deb() {
    local vendor_id="$1"
    local name="${vendor_id##*-}"
    local build_dir="$SRC/build/build-$name"
    local image="$build_dir/images/jdk"

    echo "-- packaging $vendor_id --"
    export JAVA_HOME="$BOOT/$name"

    cd "$SRC"
    rm -rf "$build_dir"

    bash configure \
        --with-boot-jdk="$JAVA_HOME" \
        --with-conf-name="build-$name" \
        --with-native-debug-symbols=none \
        --with-vendor-name="$VENDOR_NAME" \
        --with-vendor-url="$VENDOR_URL" \
        --with-version-pre= \
        --with-version-opt= \
        --disable-warnings-as-errors \
        2>&1 | tail -3

    make CONF="build-$name" images 2>&1 | tail -3
    normalize_image "$image"

    # the packaged image must match the verified hashes
    (cd "$image" && find . -type f | sort | xargs sha256sum) | diff -q - "$RESULTS/hashes-$name.txt"

    local pkg="$RESULTS/pkg"
    rm -rf "$pkg"
    mkdir -p "$pkg/DEBIAN" "$pkg$INSTALL_PREFIX"
    cp -a "$image/"* "$pkg$INSTALL_PREFIX/"

    cat > "$pkg/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: amd64
Maintainer: ${VENDOR_NAME} <${VENDOR_URL}>
Description: OpenJDK ${JDK_MAJOR} (verified build from ${JDK_TAG})
Section: java
Priority: optional
Installed-Size: $(du -sk "$pkg$INSTALL_PREFIX" | cut -f1)
EOF

    cat > "$pkg/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
JDK=INSTALL_PREFIX_PLACEHOLDER
for tool in java javac jar javadoc jshell; do
    update-alternatives --install /usr/bin/$tool $tool $JDK/bin/$tool PRIORITY_PLACEHOLDER
done
POSTINST
    sed -i "s|INSTALL_PREFIX_PLACEHOLDER|${INSTALL_PREFIX}|;s|PRIORITY_PLACEHOLDER|${JDK_MAJOR}00|" \
        "$pkg/DEBIAN/postinst"
    chmod 755 "$pkg/DEBIAN/postinst"

    cat > "$pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
for tool in java javac jar javadoc jshell; do
    update-alternatives --remove $tool INSTALL_PREFIX_PLACEHOLDER/bin/$tool || true
done
PRERM
    sed -i "s|INSTALL_PREFIX_PLACEHOLDER|${INSTALL_PREFIX}|" "$pkg/DEBIAN/prerm"
    chmod 755 "$pkg/DEBIAN/prerm"

    find "$pkg" -exec touch -d @${SOURCE_DATE_EPOCH} {} + 2>/dev/null || true

    local deb="$RESULTS/${PKG_NAME}_${PKG_VERSION}_amd64.deb"
    dpkg-deb --root-owner-group -Zxz --build "$pkg" "$deb"
    echo "  $(basename "$deb") ($(du -h "$deb" | cut -f1))"

    rm -rf "$pkg" "$build_dir"
}

# -- Main --

START=$(date +%s)
for v in "${VENDORS[@]}"; do build_vendor "$v"; done
ELAPSED=$(( $(date +%s) - START ))

echo "Build time: $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
echo ""

# -- Compare --

cd "$RESULTS"
ref="${VENDORS[0]##*-}"

echo "-- Comparison (reference: $ref) --"
echo ""
all_ok=true
for v in "${VENDORS[@]:1}"; do
    name="${v##*-}"
    if diff -q "hashes-$ref.txt" "hashes-$name.txt" > /dev/null 2>&1; then
        echo "  $name = $ref"
    else
        echo "  $name != $ref  ***"
        diff "hashes-$ref.txt" "hashes-$name.txt" | head -20 \
            > "diff-${ref}-vs-${name}.txt"
        all_ok=false
    fi
done

echo ""
if [ "$all_ok" = true ]; then
    echo "RESULT: ALL ${#VENDORS[@]} VENDORS IDENTICAL"
    echo ""
    # build final .deb from first vendor (verified)
    package_deb "${VENDORS[0]}"
else
    echo "RESULT: MISMATCH DETECTED"
    exit 1
fi

echo ""
ls -lh "$RESULTS"/*.deb 2>/dev/null
