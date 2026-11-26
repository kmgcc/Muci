#!/usr/bin/env bash
set -euo pipefail

src="$PROJECT_DIR/Tools/MuciInstallMigration/main.m"
dst_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
dst="$dst_dir/muci-install-migration"

arch_flags=()
for arch in $ARCHS; do
  arch_flags+=(-arch "$arch")
done

mkdir -p "$dst_dir"
/usr/bin/xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -O2 \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" "${arch_flags[@]}" \
  -framework AppKit -framework Security "$src" -o "$dst"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --identifier muci-install-migration \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$dst"
fi
