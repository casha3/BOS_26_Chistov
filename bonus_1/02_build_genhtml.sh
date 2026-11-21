#!/usr/bin/env bash
#
# 02_build_genhtml.sh - build the PATCHED genhtml utility.
#
# It downloads the LCOV 1.16 source tree (the last classic release whose
# genhtml is a single self-contained Perl script), keeps the pristine
# genhtml as genhtml_orig and applies our patch (patch/genhtml.patch)
# which adds
#
#   --bb-report FILENAME
#
# to the tool.  Two callable wrappers are created:
#
#   vendor/genhtml       - patched genhtml (Basic Block Coverage support)
#   vendor/genhtml_orig  - original unpatched genhtml (backward compat)
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/tools/lib_common.sh"

LCOV_VERSION="1.16"
LCOV_URL="https://github.com/linux-test-project/lcov/releases/download/v${LCOV_VERSION}/lcov-${LCOV_VERSION}.tar.gz"
VENDOR_DIR="$ROOT/vendor"

mkdir -p "$VENDOR_DIR"

if [ ! -x "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" ]; then
    if [ ! -f "$VENDOR_DIR/lcov-${LCOV_VERSION}.tar.gz" ]; then
        log "Downloading LCOV ${LCOV_VERSION} from $LCOV_URL"
        ( cd "$VENDOR_DIR" && curl -fL -o "lcov-${LCOV_VERSION}.tar.gz" "$LCOV_URL" )
    fi
    log "Extracting LCOV ${LCOV_VERSION}"
    tar -xzf "$VENDOR_DIR/lcov-${LCOV_VERSION}.tar.gz" -C "$VENDOR_DIR"
fi

log "Backing up the pristine genhtml"
cp -f "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" \
      "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig"

if ! grep -q "bb-report" "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml"; then
    log "Applying patch/genhtml.patch"
    ( cd "$VENDOR_DIR/lcov-${LCOV_VERSION}" \
      && patch -p1 < "$PATCH_DIR/genhtml.patch" )
fi

chmod +x "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" \
         "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig"

cat > "$GENHTML" <<EOF
#!/usr/bin/env bash
exec "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" "\$@"
EOF
chmod +x "$GENHTML"

cat > "$GENHTML_ORIG" <<EOF
#!/usr/bin/env bash
exec "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig" "\$@"
EOF
chmod +x "$GENHTML_ORIG"

echo "==> Patched genhtml: $GENHTML"
echo "==> Original genhtml (compat): $GENHTML_ORIG"
echo "==> Checking option support:"
"$GENHTML" --version
"$GENHTML" --help | grep -A2 "bb-report" || true