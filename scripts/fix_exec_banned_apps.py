#!/usr/bin/env python3
"""Чинит аварию ядра в fs/exec.c (блок «BannedApps» в do_execveat_common).

Что было: при каждом запуске app_process ядро делало kmalloc(MAX_ARG_STRLEN) = 128 КБ
(страница порядка 5), не проверяло результат и сразу memset(arg, 0, 128 КБ) на КАЖДЫЙ аргумент.
Когда память фрагментирована, выделение порядка 5 проваливается, возвращается NULL,
memset(NULL) даёт Oops в процессе `input`, а Oops превращается в panic и перезагрузку по watchdog.

Что делаем: оставляем саму функцию блокировки (список BannedApps не трогаем), но берём маленький
буфер 1 КБ вместо 128 КБ, проверяем результат kmalloc (нет памяти: пропускаем проверку, а не падаем)
и ограничиваем длину копируемой строки размером буфера (раньше она могла быть до 128 КБ).
Идемпотентен: повторный запуск ничего не меняет. Если шаблон не найден, завершается с ошибкой,
чтобы билд не прошёл молча без фикса.
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
p = root / "fs/exec.c"
s = p.read_text(encoding="utf-8", errors="surrogateescape")

if "KKNX_ARG_BUF" in s:
    print("fix_exec_banned_apps: уже применён")
    sys.exit(0)

if "BannedApps" not in s:
    print("fix_exec_banned_apps: в этом дереве нет блока BannedApps, делать нечего")
    sys.exit(0)

edits = [
    # размер буфера
    ("static int do_execveat_common(int fd, struct filename *filename,",
     "#define KKNX_ARG_BUF 1024\n\nstatic int do_execveat_common(int fd, struct filename *filename,"),
    # выделение: маленький буфер + проверка
    ("arg  = kmalloc(MAX_ARG_STRLEN, GFP_KERNEL);",
     "arg  = kmalloc(KKNX_ARG_BUF, GFP_KERNEL);\n\t\tif (!arg)\n\t\t\targc = 0;   /* нет памяти: пропускаем проверку, а не падаем */"),
    # обнуление буфера
    ("memset(arg, 0, MAX_ARG_STRLEN);",
     "memset(arg, 0, KKNX_ARG_BUF);"),
    # длина строки не больше буфера (последний байт остаётся нулём после memset)
    ("len = strnlen_user(str, MAX_ARG_STRLEN);\n\n\t\t\t// Copy to kernel memory",
     "len = strnlen_user(str, KKNX_ARG_BUF - 1);\n\t\t\tif (len > KKNX_ARG_BUF - 1)\n\t\t\t\tlen = KKNX_ARG_BUF - 1;\n\n\t\t\t// Copy to kernel memory"),
]
for old, new in edits:
    if s.count(old) != 1:
        print("fix_exec_banned_apps: ОШИБКА, шаблон найден %d раз (нужен ровно 1): %r" % (s.count(old), old[:60]))
        sys.exit(1)
    s = s.replace(old, new)

p.write_text(s, encoding="utf-8", errors="surrogateescape")
print("fix_exec_banned_apps: применён (буфер 1 КБ вместо 128 КБ, проверка NULL)")
