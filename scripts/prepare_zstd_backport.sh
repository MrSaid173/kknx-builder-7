#!/usr/bin/env bash
set -euo pipefail

# Импортёр исходников для эксперимента ZSTD.
# Дерево 4.9 содержит kernel-zstd 1.3.1 (эпоха 4.14). Тот же 1.3.1 лежит и в Linux 5.10.x, поэтому он не годится:
# обновление до zstd 1.4.10 (новая раскладка lib/zstd/{common,compress,decompress} и kernel-style API zstd_*)
# вошло только в Linux 5.16. Берём оттуда (ZSTD_REF можно переопределить, например v5.16.20 или v6.1).

REF="${ZSTD_REF:-v5.16}"
REPO="${ZSTD_REPO:-https://github.com/gregkh/linux.git}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/backports/zstd"
TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kknx-zstd-${REF}"

rm -rf "$TMP" "$DEST"
mkdir -p "$DEST"

echo "[zstd-backport] fetching $REPO $REF"
git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$REF" "$REPO" "$TMP"
test "$(git -C "$TMP" describe --tags --exact-match HEAD 2>/dev/null)" = "$REF"

git -C "$TMP" sparse-checkout init --no-cone
git -C "$TMP" sparse-checkout set /include/linux/zstd.h /include/linux/zstd_errors.h /include/linux/zstd_lib.h /lib/zstd/
# после clone --no-checkout sparse-checkout сам файлы не выкладывает: нужен явный checkout
git -C "$TMP" checkout -q

git -C "$TMP" rev-parse HEAD > "$DEST/REV.txt"
printf 'source: Linux %s\nrepo: %s\ncommit: %s\npaths: include/linux/zstd*.h + lib/zstd/**\n' \
  "$REF" "$REPO" "$(cat "$DEST/REV.txt")" > "$DEST/SOURCE.txt"

mkdir -p "$DEST/include/linux" "$DEST/lib/zstd"
cp "$TMP"/include/linux/zstd*.h "$DEST/include/linux/"
cp -a "$TMP/lib/zstd/." "$DEST/lib/zstd/"

# Проверяем структуру, а не количество файлов (в 5.10 их 8 .c + 7 .h, в 5.16+ раскладка другая)
for f in include/linux/zstd.h include/linux/zstd_errors.h include/linux/zstd_lib.h lib/zstd/Makefile \
         lib/zstd/zstd_compress_module.c lib/zstd/zstd_decompress_module.c \
         lib/zstd/compress/zstd_compress.c lib/zstd/decompress/zstd_decompress.c; do
  [ -s "$DEST/$f" ] || { echo "[zstd-backport] ОШИБКА: нет $f в $REF (не та версия?)" >&2; exit 1; }
done
grep -q 'zstd_init_cctx' "$DEST/include/linux/zstd.h" \
  || { echo "[zstd-backport] ОШИБКА: в $REF нет kernel-style API zstd_*; нужен Linux 5.16 или новее" >&2; exit 1; }

c_count="$(find "$DEST/lib/zstd" -type f -name '*.c' | wc -l)"
h_count="$(find "$DEST/lib/zstd" -type f -name '*.h' | wc -l)"
echo "[zstd-backport] prepared $REF: $c_count C + $h_count H"
rm -rf "$TMP"
