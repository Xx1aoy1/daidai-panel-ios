#!/bin/bash
#
# 把 BeeWare Python.xcframework 的标准库装进 App bundle。
#
# 背景（来自 Python.xcframework/build/utils.sh 的说明）：
#   xcframework 里只能放二进制和元数据，放不了标准库；而且 iOS 要求可动态
#   加载的库必须位于 .framework 内。所以必须：
#     1) 把 stdlib 复制到 <App>.app/python/lib/python3.x
#     2) 把 lib-dynload 下的每个 .so 转成 Frameworks/<name>.framework/<name>，
#        并在原位置留下 <name>.so.fwork 指针文件
#
# 与官方脚本唯一的差别：官方脚本最后会 codesign，我们做的是免签名 IPA，
# 所以跳过签名（TrollStore / 侧载工具会在安装时统一重签）。

set -euo pipefail

APP="${CODESIGNING_FOLDER_PATH:-}"
if [ -z "$APP" ]; then
  echo "[daidai] 错误：CODESIGNING_FOLDER_PATH 未设置，脚本必须在 Xcode 构建阶段运行"
  exit 1
fi

XCF="${SRCROOT}/Frameworks/Python.xcframework"
if [ ! -d "$XCF" ]; then
  echo "[daidai] 错误：找不到 $XCF"
  echo "[daidai] 请先运行 Scripts/fetch_python.sh 下载 Python 运行时"
  exit 1
fi

echo "[daidai] 目标 App: $APP"

# ---------- 1. 选择 slice ----------
if [ "${EFFECTIVE_PLATFORM_NAME:-}" = "-iphonesimulator" ]; then
  if [ -d "$XCF/ios-arm64-simulator" ]; then
    SLICE="ios-arm64-simulator"
  else
    SLICE="ios-arm64_x86_64-simulator"
  fi
else
  SLICE="ios-arm64"
fi

SLICE_ARCH=""
for d in "$XCF/$SLICE"/lib-*; do
  if [ -d "$d" ]; then
    SLICE_ARCH="$(basename "$d")"
    break
  fi
done

echo "[daidai] slice=$SLICE arch=$SLICE_ARCH"

# ---------- 2. 复制标准库 ----------
DEST="$APP/python/lib"
mkdir -p "$DEST"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude 'libpython*.dylib' "$XCF/lib/" "$DEST/"
  if [ -n "$SLICE_ARCH" ]; then
    rsync -a --exclude 'libpython*.dylib' "$XCF/$SLICE/$SLICE_ARCH/" "$DEST/"
  fi
else
  cp -R "$XCF/lib/." "$DEST/"
  if [ -n "$SLICE_ARCH" ]; then
    cp -R "$XCF/$SLICE/$SLICE_ARCH/." "$DEST/"
  fi
  find "$DEST" -name 'libpython*.dylib' -delete
fi

PYTHON_VER="$(ls -1 "$DEST" | grep -E '^python3\.[0-9]+$' | head -1 || true)"
if [ -z "$PYTHON_VER" ]; then
  echo "[daidai] 错误：没有在 $DEST 找到 python3.x 标准库目录"
  exit 1
fi
echo "[daidai] Python 标准库版本：$PYTHON_VER"

# ---------- 3. .so -> .framework ----------
INFO_TEMPLATE="$XCF/build/iOS-dylib-Info-template.plist"
if [ "${EFFECTIVE_PLATFORM_NAME:-}" = "-iphonesimulator" ]; then
  [ -f "$XCF/build/iOS-simulator-dylib-Info-template.plist" ] && \
    INFO_TEMPLATE="$XCF/build/iOS-simulator-dylib-Info-template.plist"
fi

convert_so() {
  local FULL_EXT="$1"
  local EXT MODULE_PATH MODULE_NAME RELATIVE_EXT PYTHON_EXT FULL_MODULE_NAME FRAMEWORK_FOLDER BUNDLE_ID

  EXT="$(basename "$FULL_EXT")"
  MODULE_PATH="$(dirname "$FULL_EXT")"
  MODULE_NAME="${EXT%%.*}"
  RELATIVE_EXT="${FULL_EXT#"$APP"/}"
  PYTHON_EXT="${RELATIVE_EXT#"python/lib/$PYTHON_VER/"}"
  FULL_MODULE_NAME="$(echo "$PYTHON_EXT" | cut -d "." -f 1 | tr "/" ".")"
  FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"
  BUNDLE_ID="$(echo "${PRODUCT_BUNDLE_IDENTIFIER:-com.daidai.panel}.$FULL_MODULE_NAME" | tr "_" "-")"

  mkdir -p "$APP/$FRAMEWORK_FOLDER"
  cp "$INFO_TEMPLATE" "$APP/$FRAMEWORK_FOLDER/Info.plist"
  plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$APP/$FRAMEWORK_FOLDER/Info.plist" >/dev/null
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/$FRAMEWORK_FOLDER/Info.plist" >/dev/null

  mv "$FULL_EXT" "$APP/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"

  # 占位文件：告诉打了 iOS 补丁的 CPython 真正的二进制在哪
  echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > "${FULL_EXT%.so}.fwork"
  echo "${RELATIVE_EXT%.so}.fwork" > "$APP/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"

  if [ -e "$MODULE_PATH/$MODULE_NAME.xcprivacy" ]; then
    mv "$MODULE_PATH/$MODULE_NAME.xcprivacy" "$APP/$FRAMEWORK_FOLDER/PrivacyInfo.xcprivacy"
  fi
}

LIBDYNLOAD="$DEST/$PYTHON_VER/lib-dynload"
COUNT=0
if [ -d "$LIBDYNLOAD" ]; then
  while IFS= read -r so; do
    convert_so "$so"
    COUNT=$((COUNT + 1))
  done < <(find "$LIBDYNLOAD" -name "*.so")
fi
echo "[daidai] 已转换 $COUNT 个二进制扩展模块为 framework"

# ---------- 4. 安装第三方纯 Python 包 ----------
SITE_SRC="${SRCROOT}/Resources/py/site-packages"
if [ -d "$SITE_SRC" ] && [ -n "$(ls -A "$SITE_SRC" 2>/dev/null || true)" ]; then
  SITE_DEST="$DEST/$PYTHON_VER/site-packages"
  mkdir -p "$SITE_DEST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$SITE_SRC/" "$SITE_DEST/"
  else
    cp -R "$SITE_SRC/." "$SITE_DEST/"
  fi
  echo "[daidai] 已安装 site-packages: $(ls -1 "$SITE_SRC" | tr '\n' ' ')"
else
  echo "[daidai] 未发现 site-packages（仅标准库可用）"
fi

# ---------- 5. 收尾 ----------
rm -rf "$APP/py" 2>/dev/null || true
echo "[daidai] Python 运行时安装完成 -> $DEST"
