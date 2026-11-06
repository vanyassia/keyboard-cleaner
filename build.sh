#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="KeyboardCleaner"
APP_BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
ICONSET_DIR="${SCRIPT_DIR}/icon.iconset"
ICON_BUILDER="${SCRIPT_DIR}/make_icon"
ICON_FILE="${SCRIPT_DIR}/AppIcon.icns"
RELEASE_DIR="${SCRIPT_DIR}/release"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
MODULE_CACHE_DIR="${SWIFT_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/KeyboardCleaner-ModuleCache}"
ARCHITECTURES="${ARCHITECTURES:-arm64 x86_64}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-12.0}"
# Name of a keychain profile created with `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BINARY_BUILD_DIR="${TMPDIR:-/tmp}/KeyboardCleaner-bin"

echo "=== Сборка ${APP_NAME} ${VERSION} (${BUILD_NUMBER}) ==="

mkdir -p "$MODULE_CACHE_DIR"

echo "Очистка предыдущих артефактов..."
rm -rf "$APP_BUNDLE" "$ICONSET_DIR" "$ICON_BUILDER" "$ICON_FILE"

echo "Создание структуры бандла..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "Генерация иконки..."
swiftc -module-cache-path "$MODULE_CACHE_DIR" "$SCRIPT_DIR/make_icon.swift" -o "$ICON_BUILDER"
(cd "$SCRIPT_DIR" && "$ICON_BUILDER")
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR" "$ICON_BUILDER" "$ICON_FILE"

echo "Компиляция основного приложения (${ARCHITECTURES})..."
rm -rf "$BINARY_BUILD_DIR"
mkdir -p "$BINARY_BUILD_DIR"
ARCH_BINARIES=()
for ARCH in $ARCHITECTURES; do
    swiftc -O -whole-module-optimization \
        -module-cache-path "$MODULE_CACHE_DIR" \
        -target "${ARCH}-apple-macosx${MACOS_MIN_VERSION}" \
        "$SCRIPT_DIR/main.swift" \
        -o "$BINARY_BUILD_DIR/${APP_NAME}-${ARCH}"
    ARCH_BINARIES+=("$BINARY_BUILD_DIR/${APP_NAME}-${ARCH}")
done
lipo -create "${ARCH_BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
rm -rf "$BINARY_BUILD_DIR"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "Настройка Info.plist..."
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

echo "Подписание приложения..."
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi

echo "Проверка подписи и структуры..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if [[ "${1:-}" == "archive" ]]; then
    mkdir -p "$RELEASE_DIR"
    ARCHIVE_PATH="$RELEASE_DIR/${APP_NAME}-${VERSION}.zip"
    rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

    if [[ -n "$NOTARY_PROFILE" ]]; then
        if [[ "$SIGNING_IDENTITY" == "-" ]]; then
            echo "Ошибка: для нотаризации нужна подпись Developer ID (CODE_SIGN_IDENTITY)." >&2
            exit 1
        fi
        echo "Нотаризация (может занять несколько минут)..."
        xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP_BUNDLE"
        xcrun stapler validate "$APP_BUNDLE"
        spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
        # Re-pack so the published archive contains the stapled ticket.
        rm -f "$ARCHIVE_PATH"
        ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
    elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "Внимание: ad-hoc подпись. Gatekeeper предупредит пользователей при первом запуске."
    fi

    (cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256")
    echo "Архив релиза: $ARCHIVE_PATH"
    echo "SHA-256: $(cut -d' ' -f1 "$ARCHIVE_PATH.sha256")"
fi

echo "=== Сборка успешно завершена ==="
echo "Приложение: $APP_BUNDLE"
