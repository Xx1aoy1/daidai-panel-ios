#!/bin/bash
#
# 把构建产物打包成免签名的 .ipa（供 TrollStore / 巨魔 安装）
#
# 产物：dist/daidai-panel-<版本>-unsigned.ipa
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="daidai-panel"
BUILD_DIR="${BUILD_DIR:-build}"
CONFIG="${CONFIG:-Release}"
DIST_DIR="dist"

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}-iphoneos/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
  echo "[daidai] 找不到构建产物：$APP_PATH"
  echo "[daidai] 先执行 xcodebuild，或设置 BUILD_DIR 环境变量"
  exit 1
fi

echo "[daidai] 检查 Python 运行时是否已打进 App"
if [ ! -d "$APP_PATH/python/lib" ]; then
  echo "[daidai] 警告：$APP_PATH/python/lib 不存在，Python 脚本将无法运行"
  echo "[daidai] 说明 postBuildScripts（install_python.sh）没有生效"
else
  PY_VER="$(ls -1 "$APP_PATH/python/lib" | grep -E '^python3\.[0-9]+$' | head -1 || true)"
  echo "[daidai]   标准库版本：${PY_VER:-未知}"
  echo "[daidai]   lib-dynload 已转换模块：$(find "$APP_PATH/python/lib" -name '*.fwork' 2>/dev/null | wc -l | tr -d ' ') 个"
  echo "[daidai]   Frameworks：$(ls -1 "$APP_PATH/Frameworks" 2>/dev/null | wc -l | tr -d ' ') 个"
fi

VERSION_RAW="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || echo 1.0.0)"
# 文件名安全化：'+' / 空格 换成 '-'，其余非常规字符剔除。
# 否则 '+' 在下载 URL 中会被解码成空格，导致 404。
VERSION="$(printf '%s' "$VERSION_RAW" | tr '+ ' '--' | tr -cd 'A-Za-z0-9._-')"
[ -z "$VERSION" ] && VERSION="1.0.0"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist" 2>/dev/null || echo 1)"
echo "[daidai] 版本：${VERSION_RAW}（文件名用 ${VERSION}），构建号：${BUILD_NO}"

rm -rf "$DIST_DIR/Payload" "$DIST_DIR/${APP_NAME}-${VERSION}-unsigned.ipa"
mkdir -p "$DIST_DIR/Payload"
cp -R "$APP_PATH" "$DIST_DIR/Payload/"

PKG="$DIST_DIR/Payload/${APP_NAME}.app"

# ---------------------------------------------------------------------------
# ldid 伪签名
# 部分 TrollStore 版本对「完全没有签名」的 Mach-O 更挑剔，这里做 ad-hoc 签名兜底。
# 失败不影响流程（TrollStore 安装时会重新签整个包）。
# ---------------------------------------------------------------------------
if command -v ldid >/dev/null 2>&1; then
  echo "[daidai] ldid 伪签名"
  ldid -S "$PKG/$APP_NAME" 2>/dev/null && echo "   main binary ok" || echo "   main binary 跳过"

  if [ -d "$PKG/Frameworks" ]; then
    for fw in "$PKG/Frameworks"/*.framework; do
      [ -d "$fw" ] || continue
      FW_NAME="$(basename "$fw" .framework)"
      if [ -f "$fw/$FW_NAME" ]; then
        ldid -S "$fw/$FW_NAME" 2>/dev/null || true
      fi
    done
    echo "   已处理 $(ls -1 "$PKG/Frameworks" | wc -l | tr -d ' ') 个 framework"
  fi
else
  echo "[daidai] 未安装 ldid，跳过伪签名（TrollStore 安装时会自行签名）"
fi

# IPA 内不允许存在签名残留
find "$PKG" -name "_CodeSignature" -type d -prune -exec rm -rf {} + 2>/dev/null || true
rm -f "$PKG/embedded.mobileprovision"

pushd "$DIST_DIR" >/dev/null
OUT="${APP_NAME}-${VERSION}-unsigned.ipa"
rm -f "$OUT"
zip -qry "$OUT" Payload
popd >/dev/null

rm -rf "$DIST_DIR/Payload"

echo "[daidai] 打包完成：dist/${APP_NAME}-${VERSION}-unsigned.ipa"
ls -lh "dist/${APP_NAME}-${VERSION}-unsigned.ipa"
