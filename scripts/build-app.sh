#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Review Canvas"
APP_BUNDLE="${PROJECT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MERMAID_RUNTIME="${PROJECT_DIR}/node_modules/mermaid/dist/mermaid.min.js"

if [[ ! -f "${MERMAID_RUNTIME}" ]]; then
    print -u2 "Mermaid runtime이 없습니다. 먼저 프로젝트 폴더에서 npm install을 실행하세요."
    exit 1
fi

if [[ "${APP_BUNDLE}" != "${PROJECT_DIR}/dist/Review Canvas.app" ]]; then
    print -u2 "예상하지 못한 앱 출력 경로입니다: ${APP_BUNDLE}"
    exit 1
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/Licenses"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc \
    -parse-as-library \
    -O \
    -target arm64-apple-macos14.0 \
    -sdk "${SDK_PATH}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework WebKit \
    "${PROJECT_DIR}"/Sources/*.swift \
    -o "${MACOS_DIR}/ReviewCanvas"

cp "${PROJECT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_DIR}/Resources/viewer.html" "${RESOURCES_DIR}/viewer.html"
cp "${MERMAID_RUNTIME}" "${RESOURCES_DIR}/mermaid.min.js"

if [[ -f "${PROJECT_DIR}/node_modules/mermaid/LICENSE" ]]; then
    cp "${PROJECT_DIR}/node_modules/mermaid/LICENSE" "${RESOURCES_DIR}/Licenses/Mermaid-LICENSE"
fi

codesign --force --deep --sign - "${APP_BUNDLE}"

print "완료: ${APP_BUNDLE}"
