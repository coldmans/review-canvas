#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_DIR="${SCRIPT_DIR:h}"
readonly APP_NAME="Review Canvas"
readonly DIST_DIR="${PROJECT_DIR}/dist"
readonly APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
readonly EXPECTED_APP_BUNDLE="${PROJECT_DIR}/dist/Review Canvas.app"
readonly TEMP_BASE="${TMPDIR:-/tmp}"

if [[ "${APP_BUNDLE}" != "${EXPECTED_APP_BUNDLE}" ]]; then
    print -u2 "예상하지 못한 앱 출력 경로입니다: ${APP_BUNDLE}"
    exit 1
fi

for required_command in node npm xcodegen xcodebuild ditto codesign; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        print -u2 "필요한 명령을 찾을 수 없습니다: ${required_command}"
        if [[ "${required_command}" == "xcodegen" ]]; then
            print -u2 "Homebrew를 사용한다면 'brew install xcodegen'으로 설치할 수 있습니다."
        fi
        exit 1
    fi
done

readonly BUILD_ROOT="$(mktemp -d "${TEMP_BASE%/}/review-canvas-build.XXXXXX")"
readonly BUILD_MARKER="${BUILD_ROOT}/.review-canvas-build"
readonly DERIVED_DATA="${BUILD_ROOT}/DerivedData"
readonly STAGED_APP="${BUILD_ROOT}/${APP_NAME}.app"
readonly BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"

touch "${BUILD_MARKER}"

cleanup() {
    if [[ -f "${BUILD_MARKER}" && "${BUILD_ROOT}" == "${TEMP_BASE%/}"/review-canvas-build.* ]]; then
        rm -rf -- "${BUILD_ROOT}"
    fi
}
trap cleanup EXIT

print "1/4 npm lockfile로 Mermaid 런타임을 준비합니다."
(
    cd "${PROJECT_DIR}"
    npm ci --ignore-scripts --no-audit --no-fund
)

readonly MERMAID_RUNTIME="${PROJECT_DIR}/node_modules/mermaid/dist/mermaid.min.js"
if [[ ! -f "${MERMAID_RUNTIME}" ]]; then
    print -u2 "Mermaid 런타임을 준비하지 못했습니다: ${MERMAID_RUNTIME}"
    exit 1
fi

print "2/4 Xcode 프로젝트를 생성합니다."
(
    cd "${PROJECT_DIR}"
    xcodegen generate
)

print "3/4 macOS Release 앱을 빌드합니다."
xcodebuild \
    -project "${PROJECT_DIR}/ReviewCanvas.xcodeproj" \
    -scheme ReviewCanvas-macOS \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "${BUILT_APP}" ]]; then
    print -u2 "빌드된 앱을 찾을 수 없습니다: ${BUILT_APP}"
    exit 1
fi

print "4/4 앱을 검증하고 dist에 설치합니다."
ditto "${BUILT_APP}" "${STAGED_APP}"
codesign --force --deep --sign - "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"

mkdir -p "${DIST_DIR}"
if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf -- "${APP_BUNDLE}"
fi
mv "${STAGED_APP}" "${APP_BUNDLE}"

print "완료: ${APP_BUNDLE}"
