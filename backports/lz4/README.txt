Обновлённый LZ4 (библиотека + вызывающие файлы) из стабильной ветки Linux v4.19.325 (LZ4 1.8.3 + правки ядра).
Нужен для твика lz4_update: в дереве 4.9.337 лежит старая библиотека LZ4 (2011-2012, API lz4_compress/lz4_decompress),
в 4.11 её заменили на новую (API LZ4_compress_default/LZ4_decompress_safe). Формат данных не менялся:
старый и новый код читают поток друг друга.

Файлы копируются в дерево как есть:
  lib/lz4/*, include/linux/lz4.h, lib/decompress_unlz4.c, fs/squashfs/lz4_wrapper.c
Файлы crypto/lz4.c, crypto/lz4hc.c и fs/pstore/platform.c правятся точечно скриптом apply_tweaks.py (в 4.19 они
написаны под API scomp, которого в 4.9 нет).

Лицензии файлов сохранены (BSD 2-Clause для кода LZ4 Yann Collet, GPL-2.0 для обвязки ядра).
