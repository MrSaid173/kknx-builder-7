#!/usr/bin/env python3
"""Эксперимент honestfreq: ставит в DT честные верхние частоты CPU.

Замеры на телефоне (kknx-test freqtable): на стоковых ступенях заявленная частота равна реальной (разница 0,3%),
а на двух верхних «разогнанных» ступенях реальная частота сильно ниже заявленной:
    ядра 0-3: заявлено 2616 МГц, реально 2299 МГц (2304 = 120 x 19,2 МГц)
    ядра 4-7: заявлено 2568 МГц, реально 1609 МГц (1612,8 = 84 x 19,2 МГц)
Планировщик (sched-energy) и schedutil считают ёмкость кластеров по заявленным числам, поэтому думают, что
кластер 4-7 почти так же быстр, как 0-3 (на деле на 30% медленнее), и держат на нём тяжёлые потоки.

Что делаем: заменяем эти два числа на реальные везде в arch/arm64/boot/dts/qcom: в таблицах ступеней
(Гц, speedN-bin-v0-c0/c1) и в таблицах стоимости sched-energy (кГц, busy-cost-data). Номера корнеров
напряжения (второе число в таблицах ступеней) НЕ меняются, то есть напряжения остаются прежними.
Реальная скорость процессора не меняется: она и сейчас упирается в эти же 2304 и 1612,8 МГц.
Идемпотентен. Если ничего не найдено, завершается с ошибкой (чтобы эксперимент не прошёл молча).
Переопределение: HONEST_C1_KHZ (ядра 0-3, по умолчанию 2304000), HONEST_C0_KHZ (ядра 4-7, по умолчанию 1613000, то есть 1612,8 МГц, округлённые до целых).
"""
import os, re, sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
c1 = int(os.environ.get("HONEST_C1_KHZ", "2304000"))   # было 2616000
c0 = int(os.environ.get("HONEST_C0_KHZ", "1613000"))   # было 2568000
REPL = {2616000: c1, 2568000: c0}

total = 0
files = 0
for p in sorted((root / "arch/arm64/boot/dts/qcom").glob("*.dts*")):
    s = p.read_text(encoding="utf-8", errors="surrogateescape")
    n = 0
    for old, new in REPL.items():
        # кГц (таблицы стоимости) и Гц (таблицы ступеней); границы по цифрам, чтобы не задеть другие числа
        for suffix, mult in (("", 1), ("000", 1000)):
            pat = re.compile(r"(?<![0-9])%d%s(?![0-9])" % (old, suffix))
            rep = str(new * (1000 if suffix else 1))
            s, k = pat.subn(rep, s)
            n += k
    if n:
        p.write_text(s, encoding="utf-8", errors="surrogateescape")
        print("honest_cpu_freq: %s: заменено %d" % (p.name, n))
        total += n
        files += 1

if total == 0:
    if list((root / "arch/arm64/boot/dts/qcom").glob("*.dts*")) and \
       any("%d" % c1 in f.read_text(errors="ignore") for f in (root / "arch/arm64/boot/dts/qcom").glob("*.dts*")):
        print("honest_cpu_freq: уже применён")
        sys.exit(0)
    print("honest_cpu_freq: ОШИБКА: значения 2616000/2568000 в DT не найдены")
    sys.exit(1)
print("honest_cpu_freq: всего замен %d в %d файлах: ядра 0-3 -> %d кГц, ядра 4-7 -> %d кГц" % (total, files, c1, c0))
