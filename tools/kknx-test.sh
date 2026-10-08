#!/system/bin/sh
# kknx-test.sh v2: диагностика и замеры ядра KKNX (Redmi 8/8A, mi439)
#
# Запуск от root. Termux:  su -c "sh /sdcard/Download/kknx-test.sh diag"
#                 adb:     adb shell, затем su, затем sh /sdcard/Download/kknx-test.sh diag
#
#   diag               снимок состояния: ядро, cpufreq, sched, память, I/O, GPU, шина, термо, скрипты прошивки
#   quick [метка]      быстрый замер (CPU на 1 и на всех ядрах, память, диск), около 1 минуты; строка идёт в results.csv
#   ui                 плавность: прокрутка списка приложений в Настройках + статистика кадров
#   mem [пакеты...]    удержание фоновых приложений: открывает N приложений и смотрит, сколько осталось в памяти
#   zram               скорость сжатия/распаковки zram (lz4, lzo, zstd) на отдельном временном устройстве
#   sustain [минут]    нагрузка на все ядра (по умолчанию 6 мин): как падает скорость и растёт температура
#   all [метка]        всё по очереди
#
# Результаты: /data/local/tmp/kknx/ (копия отчёта diag кладётся в /sdcard/Download).
# Скрипт ничего не меняет в системе, кроме временных файлов в /data/local/tmp/kknx и сброса кэшей (drop_caches).
# Серийные номера и MAC из отчёта вырезаны, но перед отправкой всё равно просмотрите файл.

TMP=/data/local/tmp/kknx
[ -d /data/local/tmp ] || TMP=${TMPDIR:-/tmp}/kknx
mkdir -p "$TMP" 2>/dev/null
TS=$(date +%Y%m%d-%H%M%S)
CSV="$TMP/results.csv"

say() { printf '%s\n' "$*"; }
sec() { printf '\n=== %s ===\n' "$*"; }
rd() { [ -r "$1" ] && head -n 1 "$1" 2>/dev/null; }
now_cs() { read _u _r < /proc/uptime; echo "${_u%.*}${_u#*.}"; }          # сантисекунды с загрузки
fmt2() { printf '%d.%02d' $(($1 / 100)) $(($1 % 100)); }                 # сантисекунды -> секунды
mbps() { [ "$2" -gt 0 ] 2>/dev/null || { echo "-"; return; }; v=$(($1 * 1000 / $2)); printf '%d.%d' $((v / 10)) $((v % 10)); }
per_s() { [ "$2" -gt 0 ] 2>/dev/null || { echo "-"; return; }; echo $(($1 * 100 / $2)); }

dumpdir() { # каталог [макс. файлов]: имя = значение для всех обычных файлов
  [ -d "$1" ] || { say "(нет $1)"; return; }
  n=0
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in uevent|*serial*|cid|csd|*_cid) continue ;; esac
    n=$((n + 1)); [ "$n" -gt "${2:-60}" ] && { say "... (обрезано)"; break; }
    printf '%s = ' "${f##*/}"
    head -c 160 "$f" 2>/dev/null | tr '\n' ' '
    echo
  done
}

# ---------------------------------------------------------------------------
#  diag
# ---------------------------------------------------------------------------
d_ident() {
  sec "Версия скрипта и время"
  say "kknx-test v2, $(date)"; say "uptime: $(uptime 2>/dev/null)"
  sec "Ядро"
  uname -a
  # из cmdline вырезаем серийник, MAC и прочие идентификаторы
  sed -E 's/(androidboot\.(serialno|cpuid|wifimacaddr|btmacaddr|imei[0-9a-z_]*|mac[a-z]*|ssn|uid))=[^ ]*/\1=<скрыто>/g' /proc/cmdline 2>/dev/null
  sec "Сборка ядра из /proc/config.gz (ключевые опции)"
  if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null | grep -E '^(# )?CONFIG_(LOCALVERSION=|HZ=|HZ_|PREEMPT|SCHED_(WALT|CASS|TUNE)|PELT_UTIL|CPU_FREQ_DEFAULT_GOV|CPU_FREQ_GOV_|CPU_BOOST|IOSCHED_|DEFAULT_IOSCHED|CFQ_GROUP|PSI|MEMCG|ZRAM|CRYPTO_(ZSTD|LZ4)=|ANDROID_LOW_MEMORY|SPECULATIVE_PAGE_FAULT|LTO|SDCARD_FS|F2FS_FS=|MODULES=|BPF_JIT|TCP_CONG|DEFAULT_TCP_CONG|KSU|NOMOUNT|RANDOMIZE_BASE|SECCOMP=|MMC_CQ_HCI|MMC_CLKGATE|KSM|CMA_SIZE_MBYTES|CC_OPTIMIZE|NO_HZ|RCU_NOCB)' | head -80
  else say "(нет /proc/config.gz)"; fi
  sec "Прошивка и устройство"
  getprop | grep -E '^\[(ro\.(product\.(model|device|name)|build\.(display\.id|version\.(release|sdk)|type)|board\.platform|hardware|soc\.model|vendor\.build\.(id|date)|sys\.sdcardfs|config\.[a-z_.]*|zram[a-z_.]*|lmk\.[a-z_.]*|vendor\.qti\.[a-z_.]*)|persist\.(sys\.(fuse|sdcardfs|zram|lmk|perf|ssd)[a-z_.]*|vendor\.qti\.[a-z_.]*)|external_storage\.[a-z_.]*|sys\.(use_fifo_ui|boot_completed)|dalvik\.vm\.(heap[a-z]*|usejit|dex2oat[a-z_.-]*)|debug\.(sf|hwui|renderengine)\.[a-z_.]*|ro\.lmk\.[a-z_.]*)\]' | head -80
}

d_cpu() {
  sec "CPU: cpuinfo (выжимка)"
  grep -E '^(Features|CPU part|CPU implementer|CPU revision|Hardware)' /proc/cpuinfo 2>/dev/null | sort | uniq -c | head -12
  sec "CPU: online / isolated"
  say "online=$(rd /sys/devices/system/cpu/online) possible=$(rd /sys/devices/system/cpu/possible) isolated=$(rd /sys/devices/system/cpu/isolated)"
  sec "CPU: частоты и governor по ядрам"
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*/}; p=$c/cpufreq
    [ -d "$p" ] || { say "$n: cpufreq недоступен (ядро офлайн?)"; continue; }
    say "$n: gov=$(rd $p/scaling_governor) cur=$(rd $p/scaling_cur_freq) min=$(rd $p/scaling_min_freq) max=$(rd $p/scaling_max_freq) hw_max=$(rd $p/cpuinfo_max_freq) related=$(rd $p/related_cpus) cap=$(rd $c/cpu_capacity)"
  done
  sec "CPU: доступные governor'ы, частоты и твики governor (cpu0 и cpu4)"
  for n in 0 4; do
    p=/sys/devices/system/cpu/cpu$n/cpufreq
    [ -d "$p" ] || continue
    say "cpu$n governors: $(rd $p/scaling_available_governors)"
    say "cpu$n freqs: $(rd $p/scaling_available_frequencies)"
    g=$(rd $p/scaling_governor)
    [ -n "$g" ] && { say "-- cpu$n/$g:"; dumpdir "$p/$g"; }
  done
  sec "CPU: время на частотах с момента загрузки (кГц, сотые доли секунды) и число переключений"
  for n in 0 4; do
    p=/sys/devices/system/cpu/cpu$n/cpufreq/stats
    [ -r $p/time_in_state ] || continue
    say "-- cpu$n: total_trans=$(rd $p/total_trans)"; cat $p/time_in_state
  done
  sec "CPU: cpu_boost, lpm_levels, cpuidle"
  say "-- /sys/module/cpu_boost/parameters"; dumpdir /sys/module/cpu_boost/parameters
  say "-- /sys/module/lpm_levels/parameters"; dumpdir /sys/module/lpm_levels/parameters
  for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    [ -d "$s" ] || continue
    say "cpu0 ${s##*/}: name=$(rd $s/name) latency=$(rd $s/latency) residency=$(rd $s/residency) usage=$(rd $s/usage) time_us=$(rd $s/time) disable=$(rd $s/disable)"
  done
}

d_sched() {
  sec "Планировщик: /proc/sys/kernel/sched_*"
  for f in /proc/sys/kernel/sched_*; do [ -f "$f" ] && printf '%s = %s\n' "${f##*/}" "$(rd $f)"; done
  sec "Планировщик: stune (boost / prefer_idle) и cpuset"
  for g in /dev/stune /dev/stune/*; do
    [ -d "$g" ] && [ -f "$g/schedtune.boost" ] && say "stune${g#/dev/stune}: boost=$(rd $g/schedtune.boost) prefer_idle=$(rd $g/schedtune.prefer_idle)"
  done
  for g in /dev/cpuset /dev/cpuset/*; do
    [ -d "$g" ] && [ -f "$g/cpus" ] && say "cpuset${g#/dev/cpuset}: cpus=$(rd $g/cpus)"
  done
  for g in /dev/blkio /dev/blkio/*; do
    [ -d "$g" ] && [ -f "$g/blkio.weight" ] && say "blkio${g#/dev/blkio}: weight=$(rd $g/blkio.weight)"
  done
}

d_mem() {
  sec "Память: meminfo"
  grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Active\(anon\)|Inactive\(anon\)|Active\(file\)|Inactive\(file\)|SwapTotal|SwapFree|Shmem|Slab|KernelStack|PageTables|CmaTotal|CmaFree|Mlocked)' /proc/meminfo
  sec "Память: /proc/sys/vm"
  dumpdir /proc/sys/vm 80
  sec "Память: zram"
  for z in /sys/block/zram*; do
    [ -d "$z" ] || continue
    say "-- ${z##*/}: disksize=$(rd $z/disksize) algo=$(rd $z/comp_algorithm) streams=$(rd $z/max_comp_streams)"
    say "mm_stat: $(rd $z/mm_stat)"
  done
  sec "Память: swap"; cat /proc/swaps 2>/dev/null
  sec "Память: LMK ядра и PSI"
  say "-- /sys/module/lowmemorykiller/parameters"; dumpdir /sys/module/lowmemorykiller/parameters
  for f in /proc/pressure/*; do [ -f "$f" ] && { say "-- ${f##*/}"; cat "$f"; }; done
  sec "Память: vmstat (счётчики)"
  grep -E '^(pgscan_|pgsteal_|pswp|allocstall|workingset_refault|workingset_activate|pgmajfault|kswapd_|compact_stall|oom_kill|nr_free_cma)' /proc/vmstat | tr '\n' ' '; echo
  sec "Память: watermark'и зон"
  grep -E '^Node|^  (min|low|high|managed) ' /proc/zoneinfo | head -24
}

d_io() {
  sec "Диск: mmcblk0/queue"
  dumpdir /sys/block/mmcblk0/queue 40
  say "-- iosched"; dumpdir /sys/block/mmcblk0/queue/iosched
  sec "Диск: eMMC (без серийника)"
  dumpdir /sys/block/mmcblk0/device 30
  for f in /sys/class/mmc_host/mmc0/mmc0:0001/life_time /sys/class/mmc_host/mmc0/mmc0:0001/pre_eol_info; do
    [ -r "$f" ] && say "${f##*/}=$(rd $f)"
  done
  say "-- debugfs mmc0"
  for f in clock ios; do [ -r /sys/kernel/debug/mmc0/$f ] && { printf '%s: ' $f; head -n 12 /sys/kernel/debug/mmc0/$f | tr '\n' ' '; echo; }; done
  sec "Диск: dm-* read_ahead и очереди"
  for d in /sys/block/dm-*; do [ -d "$d" ] && say "${d##*/}: ra=$(rd $d/queue/read_ahead_kb) sched=$(rd $d/queue/scheduler)"; done
  sec "Файловые системы и монтирование"
  grep -E 'sdcardfs|fuse|f2fs|ext4' /proc/filesystems | tr '\n' ' '; echo
  grep -E ' (/data|/system|/vendor|/cache|/mnt/runtime/default/emulated|/storage/emulated|/sdcard) ' /proc/mounts | cut -c1-190 | head -14
  for d in /sys/fs/f2fs/*; do [ -d "$d" ] && { say "-- f2fs ${d##*/}"; dumpdir "$d" 40; }; done
  sec "dmesg: mmc / cmdq"
  dmesg 2>/dev/null | grep -iE 'mmc0|cmdq|hs400|hs200|sdhci' | head -14
}

d_gpu() {
  sec "GPU (kgsl)"
  g=/sys/class/kgsl/kgsl-3d0
  for k in gpuclk max_gpuclk num_pwrlevels default_pwrlevel max_pwrlevel min_pwrlevel thermal_pwrlevel idle_timer force_clk_on force_bus_on force_rail_on force_no_nap gpu_busy_percentage gpu_available_frequencies; do
    [ -r $g/$k ] && printf '%s = %s\n' "$k" "$(rd $g/$k)"
  done
  say "-- devfreq"; dumpdir $g/devfreq 20
  say "-- реальная частота gfx3d (нужен debugfs)"
  rd /sys/kernel/debug/clk/gcc_oxili_gfx3d_clk/measure
  sec "devfreq: шина DDR и прочее"
  for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    say "-- ${d##*/}: gov=$(rd $d/governor) cur=$(rd $d/cur_freq) min=$(rd $d/min_freq) max=$(rd $d/max_freq)"
    say "   freqs: $(rd $d/available_frequencies)"
    for h in $d/*hwmon* $d/bw_hwmon; do [ -d "$h" ] && { say "   [${h##*/}]"; dumpdir "$h" 30; }; done
  done
}

d_thermal() {
  sec "Термо: зоны"
  for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] && say "${z##*/}: $(rd $z/type) = $(rd $z/temp)"
  done | head -40
  sec "Термо: батарея"
  for k in capacity temp status health current_now voltage_now; do
    [ -r /sys/class/power_supply/battery/$k ] && printf '%s = %s\n' $k "$(rd /sys/class/power_supply/battery/$k)"
  done
  sec "Термо: процессы thermal-engine"
  ps -A 2>/dev/null | grep -iE 'thermal|perf|mi_thermald|thermanager' | head -8
}

d_vendor() {
  sec "Скрипты прошивки, которые трогают CPU/память/диск"
  for f in /vendor/bin/init.qcom.post_boot.sh /vendor/bin/init.qcom.sh /system/vendor/bin/init.qcom.post_boot.sh; do
    [ -r "$f" ] || continue
    say "-- $f (строки про governor/sched/vm/devfreq/kgsl/queue/zram/lmk)"
    grep -nE 'scaling_governor|scaling_m(in|ax)_freq|schedutil|interactive|sched_|swappiness|extra_free|min_free|watermark|vfs_cache|dirty_|page-cluster|devfreq|kgsl|/queue/|read_ahead|zram|lowmemorykiller|minfree|cpu_boost|stune|cpuset|iowait|hispeed|rate_limit|hmp|core_ctl' "$f" | cut -c1-170 | head -150
    break
  done
  sec "init.rc: наши файлы и blkio"
  ls -l /vendor/etc/init/init.kknx.rc /vendor/etc/init/init.lolz.rc 2>&1 | cut -c1-150
  [ -r /vendor/etc/init/init.kknx.rc ] && { say "-- init.kknx.rc"; cat /vendor/etc/init/init.kknx.rc; }
  grep -rnE 'blkio|schedtune|cpuset|swappiness|extra_free' /system/etc/init /vendor/etc/init 2>/dev/null | cut -c1-170 | head -40
  sec "perf HAL / powerhint"
  ls /vendor/etc/perf /vendor/etc/powerhint.json /vendor/etc/powerhint* 2>/dev/null | head -20
}

d_memmap() {
  sec "Карта памяти (/proc/iomem: System RAM и зарезервированное)"
  grep -iE 'system ram|reserved|ramoops|kernel (code|data)|crash' /proc/iomem 2>/dev/null | head -40
  sec "pstore (журнал прошлой аварии, если он есть)"
  ls -l /sys/fs/pstore 2>&1 | head -12
  for f in /proc/last_kmsg /sys/fs/pstore/console-ramoops /sys/fs/pstore/console-ramoops-0; do
    [ -r "$f" ] && say "$f: $(wc -c < $f) байт"
  done
}

d_log() {
  sec "dmesg: ошибки и важное (до 120 строк)"
  dmesg 2>/dev/null | grep -iE 'kknx|cpu_boost|schedutil|lowmemory|lmk|oom|thermal|throttl|panic|oops|bug:|warn|zram|kgsl|cpr|fail|error' | grep -viE 'wlan|wifi|bluetooth' | tail -n 120 | cut -c1-200
  sec "logcat: lmkd (последние 40)"
  logcat -d -s lmkd 2>/dev/null | tail -n 40 | cut -c1-200
}

cmd_diag() {
  out="$TMP/diag-$TS.txt"
  say "Собираю отчёт в $out (около 10-20 секунд)..."
  { d_ident; d_cpu; d_sched; d_mem; d_io; d_gpu; d_thermal; d_vendor; d_memmap; d_log; } > "$out" 2>&1
  for d in /sdcard/Download /storage/emulated/0/Download; do
    [ -d "$d" ] && cp "$out" "$d/" 2>/dev/null && { say "Копия: $d/diag-$TS.txt"; break; }
  done
  say "Готово: $out ($(wc -c < "$out") байт). Просмотрите файл и пришлите его мне."
}

# ---------------------------------------------------------------------------
#  бинарник замеров (kknx-bench лежит рядом со скриптом; копируется в /data/local/tmp/kknx, чтобы его можно было запускать)
# ---------------------------------------------------------------------------
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
BENCH="$TMP/kknx-bench"

find_bench() {
  for c in "$HERE/kknx-bench" /sdcard/Download/kknx-bench /storage/emulated/0/Download/kknx-bench "$BENCH"; do
    [ -f "$c" ] || continue
    [ "$c" = "$BENCH" ] || cp -f "$c" "$BENCH" 2>/dev/null
    chmod 755 "$BENCH" 2>/dev/null
    [ -x "$BENCH" ] && return 0
  done
  return 1
}

need_bench() {
  find_bench && return 0
  say "Не найден kknx-bench. Положите файл kknx-bench в ту же папку, что и скрипт (например Download), и запустите снова."
  return 1
}

stable_hint() {
  say "Условия для сравнимых цифр: экран включён, зарядка отключена, телефон 5 минут в покое, одинаковый заряд и температура, фоновые синхронизации выключены (лучше режим полёта)."
}

# ---------------------------------------------------------------------------
#  время на частотах за время теста (дельта time_in_state)
# ---------------------------------------------------------------------------
tis_snap() { # метка
  for n in 0 4; do
    cat /sys/devices/system/cpu/cpu$n/cpufreq/stats/time_in_state > "$TMP/tis$n.$1" 2>/dev/null
  done
}

tis_report() { # от метки до метки; печатает долю времени на каждой частоте
  for n in 0 4; do
    [ -s "$TMP/tis$n.$1" ] && [ -s "$TMP/tis$n.$2" ] || continue
    while read -r f t; do eval "b_$f=$t"; done < "$TMP/tis$n.$1"
    tot=0
    while read -r f t; do eval "b=\${b_$f:-0}"; tot=$((tot + t - b)); done < "$TMP/tis$n.$2"
    [ "$tot" -gt 0 ] || continue
    line="cpu$n:"
    while read -r f t; do
      eval "b=\${b_$f:-0}"; d=$((t - b))
      [ "$d" -gt 0 ] && line="$line $((f / 1000))МГц=$((d * 100 / tot))%"
    done < "$TMP/tis$n.$2"
    say "$line"
  done
}

# ---------------------------------------------------------------------------
#  zram: скорость сжатия и распаковки через настоящий путь ядра (отдельное устройство, swap не трогаем)
# ---------------------------------------------------------------------------
cmd_zram() {
  [ -w /sys/class/zram-control/hot_add ] || { say "Нет /sys/class/zram-control/hot_add (нужны root и zram с hot_add)."; return 1; }
  mb=${KKNX_ZMB:-96}
  data="$TMP/zdata.bin"
  if [ ! -s "$data" ]; then
    say "Готовлю тестовые данные ($mb МБ): склеиваю родные библиотеки из /system/lib64 (сжимаются примерно как код/куча приложений)..."
    : > "$data"
    for f in /system/lib64/*.so /system/lib64/*/*.so; do
      [ -f "$f" ] || continue
      cat "$f" >> "$data"
      [ "$(wc -c < "$data")" -ge $((mb * 1048576)) ] && break
    done
    head -c $((mb * 1048576)) "$data" > "$data.cut" && mv "$data.cut" "$data"
  fi
  size=$(wc -c < "$data")
  say "Данные: $((size / 1048576)) МБ. Алгоритмы: ${KKNX_ZALGS:-lz4 lzo zstd}"
  out="$TMP/zram-$TS.txt"; : > "$out"
  for alg in ${KKNX_ZALGS:-lz4 lzo zstd}; do
    id=$(cat /sys/class/zram-control/hot_add 2>/dev/null)
    [ -n "$id" ] || { say "hot_add не сработал"; break; }
    z=/sys/block/zram$id
    if ! echo "$alg" > $z/comp_algorithm 2>/dev/null; then
      say "$alg: ядро не поддерживает"; echo "$id" > /sys/class/zram-control/hot_remove 2>/dev/null; continue
    fi
    echo "$size" > $z/disksize
    dev=/dev/block/zram$id; [ -b "$dev" ] || dev=/dev/zram$id
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    tis_snap z0
    t0=$(now_cs)
    dd if="$data" of="$dev" bs=1048576 2>/dev/null
    t1=$(now_cs)
    dd if="$dev" of=/dev/null bs=1048576 2>/dev/null
    t2=$(now_cs)
    tis_snap z1
    ms=$(cat $z/mm_stat)
    set -- $ms
    orig=$1; comp=$2
    smb=$((size / 1048576))
    ratio=$([ "${comp:-0}" -gt 0 ] && echo "$((orig * 100 / comp))" || echo 0)
    msg="$alg: сжатие+запись $(mbps $smb $((t1 - t0))) МБ/с, распаковка+чтение $(mbps $smb $((t2 - t1))) МБ/с, степень сжатия $(printf '%d.%02d' $((ratio / 100)) $((ratio % 100))):1"
    say "$msg"; echo "$msg" >> "$out"
    tis_report z0 z1 | tee -a "$out"
    echo "$id" > /sys/class/zram-control/hot_remove 2>/dev/null
  done
  say "Подробности: $out"
}

# ---------------------------------------------------------------------------
#  quick: CPU / память / диск / задержка / разгон; строка идёт в results.csv
# ---------------------------------------------------------------------------
cmd_quick() {
  need_bench || return 1
  label=$(printf '%s' "${1:-$(uname -r)}" | tr ', ' '__')
  stable_hint
  say "Замер идёт примерно 1 минуту. Не трогайте телефон."
  [ -f "$CSV" ] || "$BENCH" csvhead > "$CSV"
  out="$TMP/quick-$TS.txt"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  tis_snap q0
  "$BENCH" quick "$TMP" "$label" | tee "$out"
  tis_snap q1
  say "Время на частотах за замер (вместе с простоем между тестами):"
  tis_report q0 q1 | tee -a "$out"
  grep '^CSV,' "$out" | sed 's/^CSV,//' >> "$CSV"
  say ""
  say "Строка добавлена в $CSV. Чтобы сравнить сборки, пришлите мне этот файл целиком (cat $CSV)."
}

# ---------------------------------------------------------------------------
#  sustain: долгая нагрузка на все ядра
# ---------------------------------------------------------------------------
cmd_sustain() {
  need_bench || return 1
  say "Нагрузка на все ядра, смотрим падение скорости и температуру. Телефон станет тёплым. Минут: ${1:-6}"
  tis_snap s0
  "$BENCH" sustain "${1:-6}" | tee "$TMP/sustain-$TS.txt"
  tis_snap s1
  say "Время на частотах за всю нагрузку:"
  tis_report s0 s1 | tee -a "$TMP/sustain-$TS.txt"
}

# ---------------------------------------------------------------------------
#  ui: плавность прокрутки (кадры из gfxinfo)
# ---------------------------------------------------------------------------
cmd_ui() {
  pkg=com.android.settings
  size=$(wm size 2>/dev/null | tail -n 1 | sed 's/.*: *//')
  w=${size%x*}; h=${size#*x}
  case "$w$h" in ''|*[!0-9]*) w=720; h=1520 ;; esac
  x=$((w / 2)); y1=$((h * 78 / 100)); y2=$((h * 22 / 100))
  say "Открываю список всех приложений в Настройках и листаю его 60 раз. Не трогайте экран."
  am force-stop $pkg >/dev/null 2>&1
  am start -a android.settings.MANAGE_ALL_APPLICATIONS_SETTINGS >/dev/null 2>&1
  sleep 4
  dumpsys gfxinfo $pkg reset >/dev/null 2>&1
  i=0
  while [ $i -lt 30 ]; do
    input swipe $x $y1 $x $y2 220
    input swipe $x $y2 $x $y1 220
    i=$((i + 1))
  done
  out="$TMP/ui-$TS.txt"
  dumpsys gfxinfo $pkg | grep -E 'Total frames rendered|Janky frames|percentile|Number (Missed Vsync|High input latency|Slow UI thread|Slow bitmap uploads|Slow issue draw commands|Frame deadline missed)' | tee "$out"
  input keyevent KEYCODE_HOME
  say "Файл: $out (меньше джанка и ниже перцентили = плавнее)"
}

# ---------------------------------------------------------------------------
#  mem: сколько приложений держится в фоне
# ---------------------------------------------------------------------------
vm_snap() { grep -E '^(pgscan_direct|pgscan_kswapd|pgsteal_direct|pgsteal_kswapd|pswpin|pswpout|allocstall|workingset_refault|pgmajfault|oom_kill) ' /proc/vmstat > "$1" 2>/dev/null; }

vm_delta() {
  while read -r name before; do
    after=$(grep "^$name " "$2" | head -n 1 | sed 's/^[^ ]* //')
    [ -n "$after" ] && printf '%s=%s ' "$name" "$((after - before))"
  done < "$1"
  echo
}

launch_state() { # компонент -> "СОСТОЯНИЕ время_мс"
  r=$(am start -W -n "$1" 2>/dev/null)
  st=$(printf '%s\n' "$r" | grep -m1 'LaunchState' | sed 's/.*: *//' | tr -d '\r ')
  tt=$(printf '%s\n' "$r" | grep -m1 'TotalTime' | sed 's/.*: *//' | tr -d '\r ')
  echo "${st:-?} ${tt:--}"
}

cmd_mem() {
  list="$TMP/mem-pkgs.txt"
  max=${KKNX_APPS:-14}
  if [ $# -gt 0 ]; then
    : > "$list"
    for p in "$@"; do echo "$p" >> "$list"; done
  elif [ ! -s "$list" ]; then
    say "Подбираю приложения (сторонние, у которых есть значок запуска)..."
    : > "$list"
    n=0
    for p in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
      c=$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$p" 2>/dev/null | tail -n 1)
      case "$c" in */*) echo "$p" >> "$list"; n=$((n + 1)) ;; esac
      [ "$n" -ge "$max" ] && break
    done
    say "Выбрано $n приложений, список сохранён в $list (при повторных запусках используется тот же список; удалите файл, чтобы выбрать заново)."
  fi
  comps="$TMP/mem-comps.txt"; : > "$comps"
  while read -r p; do
    [ -n "$p" ] || continue
    c=$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$p" 2>/dev/null | tail -n 1)
    case "$c" in */*) echo "$p $c" >> "$comps" ;; *) say "  пропуск $p (нет значка запуска)" ;; esac
  done < "$list"
  total=$(wc -l < "$comps")
  [ "$total" -ge 4 ] || { say "Нужно хотя бы 4 приложения со значком запуска (найдено $total). Укажите пакеты: kknx-test.sh mem пакет1 пакет2 ..."; return 1; }

  say "Проход 1: запускаю $total приложений подряд (по 3 секунды), потом проход 2: смотрю, какие пришлось запускать заново."
  am kill-all >/dev/null 2>&1; sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; sleep 2
  vm_snap "$TMP/vm0"; mem0=$(grep -m1 MemAvailable /proc/meminfo | tr -s ' ' | cut -d' ' -f2)
  out="$TMP/mem-$TS.txt"; : > "$out"
  while read -r p c; do
    launch_state "$c" >/dev/null; sleep 3; input keyevent KEYCODE_HOME; sleep 1
  done < "$comps"
  vm_snap "$TMP/vm1"
  cold=0; sumw=0; nw=0; lost=""
  while read -r p c; do
    set -- $(launch_state "$c")
    st=$1; tt=$2
    printf '%s %s %s мс\n' "$p" "$st" "$tt" >> "$out"
    case "$st" in
      COLD) cold=$((cold + 1)); lost="$lost $p" ;;
      WARM|HOT) case "$tt" in ''|-|*[!0-9]*) ;; *) sumw=$((sumw + tt)); nw=$((nw + 1)) ;; esac ;;
    esac
    sleep 2; input keyevent KEYCODE_HOME; sleep 1
  done < "$comps"
  vm_snap "$TMP/vm2"
  kept=$((total - cold))
  say ""
  say "=== Удержание фона ==="
  say "Во втором проходе осталось в памяти: $kept из $total (холодных запусков: $cold)"
  [ -n "$lost" ] && say "Пришлось запускать заново:$lost"
  [ "$nw" -gt 0 ] && say "Среднее время тёплого/горячего запуска: $((sumw / nw)) мс"
  say "MemAvailable до: ${mem0} кБ, после: $(grep -m1 MemAvailable /proc/meminfo | tr -s ' ' | cut -d' ' -f2) кБ"
  say "Работа подсистемы памяти за проход 1: $(vm_delta "$TMP/vm0" "$TMP/vm1")"
  say "Работа подсистемы памяти за проход 2: $(vm_delta "$TMP/vm1" "$TMP/vm2")"
  [ -r /sys/block/zram0/mm_stat ] && say "zram mm_stat (исходный, сжатый, занято, лимит, макс, одинаковые страницы): $(cat /sys/block/zram0/mm_stat)"
  echo "kept=$kept total=$total cold=$cold avg_warm_ms=$([ "$nw" -gt 0 ] && echo $((sumw / nw)) || echo -)" >> "$out"
  say "Подробности: $out"
}

# ---------------------------------------------------------------------------
case "${1:-help}" in
  diag)    cmd_diag ;;
  quick)   shift; cmd_quick "$@" ;;
  ui)      cmd_ui ;;
  mem)     shift; cmd_mem "$@" ;;
  zram)    cmd_zram ;;
  sustain) shift; cmd_sustain "$@" ;;
  all)     shift; cmd_diag; cmd_quick "$@"; cmd_zram; cmd_ui; cmd_mem; cmd_sustain 4 ;;
  *)       sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
