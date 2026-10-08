KKNX ZSTD backport

Каталог заполняет scripts/prepare_zstd_backport.sh только при experiments=zstd: sparse-checkout тега Linux v5.16
(переопределяется ZSTD_REF) и копия include/linux/zstd*.h + lib/zstd/**.

Почему 5.16, а не 5.10: в дереве 4.9 лежит kernel-zstd 1.3.1 (эпоха 4.14). Тот же 1.3.1 остаётся во всех ядрах до 5.15
включительно; обновление до 1.4.10 (новая раскладка common/compress/decompress и kernel-style API zstd_*) вошло в 5.16.

apply_tweaks.py (patch_zstd): заменяет lib/zstd и заголовки, правит lib/Kconfig (ZSTD_COMMON, если нужен), Makefile
(общие объекты линкуются один раз), заменяет fallthrough на __attribute__((__fallthrough__)) только внутри lib/zstd, переводит crypto/zstd.c на
zstd_*, форсирует types.h/kernel.h/string.h через ccflags-y (только lib/zstd), включает CRYPTO_ZSTD. Остатки старого API в других файлах (squashfs, btrfs) приводят к ошибке с их списком.

По умолчанию не включено. Нужны полная сборка и загрузка на устройстве, прежде чем считать это стабильным.
