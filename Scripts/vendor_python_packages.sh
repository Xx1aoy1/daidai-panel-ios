#!/bin/bash
#
# 往 Resources/py/site-packages 里塞入纯 Python 的第三方库。
#
# 关键点：iOS 上只能跑纯 Python 包（不能跑 macOS/Linux 的二进制 wheel），
# 所以这里用 --platform any --implementation py 强制 pip 只挑 py3-none-any
# 的通用 wheel。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Resources/py/site-packages"
PY_VER="${PY_VERSION:-3.12}"

mkdir -p "$DEST"

PACKAGES=(
  requests
  urllib3
  certifi
  idna
  charset-normalizer
)

if ! command -v python3 >/dev/null 2>&1; then
  echo "[daidai] 找不到 python3，跳过第三方包安装"
  exit 1
fi

echo "[daidai] 安装纯 Python 包到 $DEST"

python3 -m pip install \
  --target "$DEST" \
  --upgrade \
  --only-binary=:all: \
  --platform any \
  --implementation py \
  --abi none \
  --python-version "$PY_VER" \
  --no-compile \
  "${PACKAGES[@]}"

# 双保险：万一混进了 .so，直接删掉（纯 Python 包里不该有）
find "$DEST" -name "*.so" -delete 2>/dev/null || true
find "$DEST" -name "*.pyd" -delete 2>/dev/null || true

echo "[daidai] 已安装："
ls -1 "$DEST" | head -30
