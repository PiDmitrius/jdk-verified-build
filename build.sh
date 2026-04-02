#!/bin/bash
# build.sh -- build, normalize, verify, package as .deb
set -o pipefail

source /opt/versions.env

export SOURCE_DATE_EPOCH
export SDKMAN_DIR=/opt/sdkman
set +u; source "$SDKMAN_DIR/bin/sdkman-init.sh"; set -u

SRC=/src/jdk
RESULTS=/results
mkdir -p "$RESULTS"

echo "OpenJDK ${JDK_MAJOR} Verified Build | ${#VENDORS[@]} vendors | ${JDK_TAG}"
echo ""

# -- Normalization: remove boot JDK traces from artifacts --

normalize_jar() {
    local jar="$1"
    local tmp
    tmp=$(mktemp -d)
    cd "$tmp"
    unzip -q -o "$jar" 2>/dev/null || { rm -rf "$tmp"; return; }
    [ -f META-INF/MANIFEST.MF ] && \
        sed -i '/^Created-By:/s/(.*)/(OpenJDK)/' META-INF/MANIFEST.MF
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
    unzip -q -o body.zip "lib/*.jar" 2>/dev/null || true
    find . -name "*.jar" -path "*/lib/*" | while read -r inner; do
        normalize_jar "$tmp/$inner"
        cd "$tmp"
        zip -X -q body.zip "$inner" 2>/dev/null || true
    done

    # repack zip for stable metadata
    local repack
    repack=$(mktemp -d)
    cd "$repack"
    unzip -q -o "$tmp/body.zip" 2>/dev/null || true
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
    sdk use java "$vendor_id"
    java -version 2>&1 | head -1

    cd "$SRC"
    rm -rf "$build_dir"

    bash configure \
        --with-boot-jdk="$JAVA_HOME" \
        --with-conf-name="build-$name" \
        --with-native-debug-symbols=none \
        --with-vendor-name="$VENDOR_NAME" \
        --with-vendor-url="$VENDOR_URL" \
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
    sdk use java "$vendor_id"

    cd "$SRC"
    rm -rf "$build_dir"

    bash configure \
        --with-boot-jdk="$JAVA_HOME" \
        --with-conf-name="build-$name" \
        --with-native-debug-symbols=none \
        --with-vendor-name="$VENDOR_NAME" \
        --with-vendor-url="$VENDOR_URL" \
        --disable-warnings-as-errors \
        2>&1 | tail -3

    make CONF="build-$name" images 2>&1 | tail -3
    normalize_image "$image"

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
update-alternatives --install /usr/bin/java java $JDK/bin/java PRIORITY_PLACEHOLDER \
    --slave /usr/bin/javac javac $JDK/bin/javac \
    --slave /usr/bin/jar jar $JDK/bin/jar \
    --slave /usr/bin/javadoc javadoc $JDK/bin/javadoc \
    --slave /usr/bin/jshell jshell $JDK/bin/jshell
POSTINST
    sed -i "s|INSTALL_PREFIX_PLACEHOLDER|${INSTALL_PREFIX}|;s|PRIORITY_PLACEHOLDER|${JDK_MAJOR}00|" \
        "$pkg/DEBIAN/postinst"
    chmod 755 "$pkg/DEBIAN/postinst"

    cat > "$pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
update-alternatives --remove java INSTALL_PREFIX_PLACEHOLDER/bin/java || true
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
fi

echo ""
ls -lh "$RESULTS"/*.deb 2>/dev/null
