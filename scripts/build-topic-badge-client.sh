#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build-logs dist

EXPECTED_CORE=25bee393e5989e8e2f720a58ff39c51fd32610ed
[ "$(git -C submodules/telegram-ios rev-parse HEAD)" = "$EXPECTED_CORE" ]

python3 - <<'PY'
from pathlib import Path
p = Path('submodules/tg_owt/src/third_party/abseil-cpp/absl/base/attributes.h')
source = p.read_text()
source = source.replace('#define ABSL_ATTRIBUTE_LIFETIME_BOUND [[clang::lifetimebound]]', '#define ABSL_ATTRIBUTE_LIFETIME_BOUND')
source = source.replace('#define ABSL_ATTRIBUTE_LIFETIME_BOUND __attribute__((lifetimebound))', '#define ABSL_ATTRIBUTE_LIFETIME_BOUND')
p.write_text(source)
p = Path('packages/ApiCredentials/Sources/ApiCredentials/Config.swift')
source = p.read_text().replace('ru.keepcoder.Telegram', 'org.freng35.TelegramTopicBadgeTest')
old = 'FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)?.appendingPathComponent(prefix)'
new = 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Telegram-TopicBadge-Test").appendingPathComponent(prefix)'
assert source.count(old) == 1
source = source.replace(old, new)
old = 'let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)\n        return containerUrl'
assert source.count(old) == 1
source = source.replace(old, 'let containerUrl: URL? = nil\n        return containerUrl')
p.write_text(source)
p = Path('Telegram.xcodeproj/project.pbxproj')
source = p.read_text()
assert 'ru.keepcoder.Telegram' in source
p.write_text(source.replace('ru.keepcoder.Telegram', 'org.freng35.TelegramTopicBadgeTest'))

p = Path('core-xprojects/tde2e/tde2e/build.sh')
source = p.read_text()
old = '    -DCMAKE_OSX_ARCHITECTURES='
assert source.count(old) == 2
source = source.replace(old, '    -DCMAKE_SYSTEM_NAME=Darwin \\\n' + old)
p.write_text(source)
PY

if ! scripts/flatc --version >/dev/null 2>&1; then
  mkdir -p .build-tools
  if [ ! -x .build-tools/flatc ]; then
    FLATBUFFERS_SOURCE="${RUNNER_TEMP}/topic-badge-flatbuffers"
    git clone --depth 1 --branch v24.12.23 https://github.com/google/flatbuffers.git "$FLATBUFFERS_SOURCE"
    [ "$(git -C "$FLATBUFFERS_SOURCE" rev-parse HEAD)" = a2cd1ea3b6d3fee220106b5fed3f7ce8da9eb757 ]
    cmake -S "$FLATBUFFERS_SOURCE" -B "$FLATBUFFERS_SOURCE/build" \
      -DCMAKE_BUILD_TYPE=Release -DFLATBUFFERS_BUILD_TESTS=OFF \
      -DFLATBUFFERS_BUILD_FLATLIB=OFF -DFLATBUFFERS_BUILD_SHAREDLIB=OFF
    cmake --build "$FLATBUFFERS_SOURCE/build" --target flatc --parallel 4
    cp "$FLATBUFFERS_SOURCE/build/flatc" .build-tools/flatc
  fi
  cp .build-tools/flatc scripts/flatc
fi
scripts/flatc --version | tee build-logs/flatc-version.log

sh scripts/configure_frameworks.sh 2>&1 | tee build-logs/frameworks.log

xcodebuild -workspace Telegram-Mac.xcworkspace \
  -scheme Telegram -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/client \
  -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build 2>&1 | tee build-logs/xcodebuild.log

APP_PATH="$ROOT_DIR/build/client/Build/Products/Debug/Telegram.app"
[ -x "$APP_PATH/Contents/MacOS/Telegram" ]
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Telegram Topic Badge Test' "$APP_PATH/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Telegram Topic Badge Test' "$APP_PATH/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
file "$APP_PATH/Contents/MacOS/Telegram"

python3 - <<'PY'
from pathlib import Path
import hashlib
import subprocess
root = Path.cwd()
paths = [
    'packages/InAppSettings/Sources/InAppSettings/ChatListFilterPreferences.swift',
    'submodules/telegram-ios/submodules/Postbox/Sources/UnreadMessageCountsView.swift',
]
lines = [
    'Unofficial test build for muted forum-topic folder badges.',
    'Architecture: arm64. Ad-hoc signed; not notarized.',
    'Profile: ~/Library/Application Support/Telegram-TopicBadge-Test/',
    'The client has a separate bundle identifier and requires a separate login.',
    'Source: ' + subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'Telegram-iOS: ' + subprocess.check_output(['git', '-C', 'submodules/telegram-ios', 'rev-parse', 'HEAD'], text=True).strip(),
]
for path in paths:
    local_hash = hashlib.sha256((root / path).read_bytes()).hexdigest()
    if path.startswith('submodules/telegram-ios/'):
        expected = subprocess.check_output(['git', '-C', 'submodules/telegram-ios', 'show', 'HEAD:' + path.removeprefix('submodules/telegram-ios/')])
    else:
        expected = subprocess.check_output(['git', 'show', '26a0c506ed9d9bb4b96384f00f6d51a0c94ff99f:' + path])
    assert local_hash == hashlib.sha256(expected).hexdigest(), path
    lines.append(f'{local_hash}  {path}')
Path('dist/build-manifest.txt').write_text('\n'.join(lines) + '\n')
PY

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" dist/Telegram-TopicBadge-Test-arm64.zip
shasum -a 256 dist/Telegram-TopicBadge-Test-arm64.zip >> dist/build-manifest.txt
