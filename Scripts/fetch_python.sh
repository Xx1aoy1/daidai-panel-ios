#!/bin/bash
#
# 下载 BeeWare 的 iOS 版 Python 运行时到 Frameworks/Python.xcframework
#
# 用法：
#   Scripts/fetch_python.sh            # 自动探测缓存 / 下载
#
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.12}"
PY_BUILD="${PY_BUILD:-b11}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Frameworks/Python.xcframework"
CACHE_DIR="$ROOT/.cache"
TARBALL="Python-${PY_VERSION}-iOS-support.${PY_BUILD}.tar.gz"

ASSET="https://github.com/beeware/Python-Apple-support/releases/download/${PY_VERSION}-${PY_BUILD}/${TARBALL}"

if [ -d "$DEST" ] && [ -f "$DEST/VERSIONS" -o -d "$DEST/ios-arm64" ]; then
  echo "[daidai] Python.xcframework 已存在，跳过下载"
  exit 0
fi

mkdir -p "$CACHE_DIR" "$ROOT/Frameworks"

if [ ! -f "$CACHE_DIR/$TARBALL" ]; then
  echo "[daidai] 下载 $ASSET"
  MIRRORS=(
    "$ASSET"
    "https://ghfast.top/$ASSET"
    "https://gh-proxy.com/$ASSET"
    "https://ghproxy.net/$ASSET"
  )
  OK=0
  for url in "${MIRRORS[@]}"; do
    echo "[daidai] 尝试: $url"
    if curl -fL --retry 2 --connect-timeout 20 --max-time 900 \
        -o "$CACHE_DIR/$TARBALL.part" "$url"; then
      mv "$CACHE_DIR/$TARBALL.part" "$CACHE_DIR/$TARBALL"
      OK=1
      break
    fi
  done
  if [ "$OK" != "1" ]; then
    echo "[daidai] 错误：所有下载源均失败"
    rm -f "$CACHE_DIR/$TARBALL.part"
    exit 1
  fi
fi

echo "[daidai] 解压到 Frameworks/"
rm -rf "$DEST"
tar xzf "$CACHE_DIR/$TARBALL" -C "$ROOT/Frameworks"

if [ ! -d "$DEST" ]; then
  echo "[daidai] 错误：解压后未找到 $DEST"
  exit 1
fi

echo "[daidai] 完成：$(du -sh "$DEST" | cut -f1)"
