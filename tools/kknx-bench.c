/*
 * kknx-bench: микробенчмарки для сравнения сборок ядра на одном и том же телефоне.
 *
 * Сборка (статический бинарник под Android arm64, без зависимостей):
 *   aarch64-linux-gnu-gcc -O2 -static -pthread -Wall -o kknx-bench kknx-bench.c
 *
 * Команды (все цифры печатаются построчно, итоговая строка CSV - для results.csv):
 *   cpu    [сек] [N | список_ядер]   пропускная способность CPU (N потоков без привязки либо потоки на ядрах "0-3,5")
 *   mem    [МБ]                      memcpy (МБ/с) и задержка случайного доступа (нс)
 *   io     <каталог> [МБ]            диск: последовательные чтение/запись, случайные 4К чтение (1 и 4 потока), запись 4К с fsync
 *   lat    [сек] [потоков_нагрузки]  задержка пробуждения (мкс) при загрузке всех ядер: p50/p90/p99/max
 *   ramp   [ядро]                    как быстро растёт производительность после простоя (мс до выхода на плато)
 *   sustain [минут]                  нагрузка на все ядра слайсами по 20 с: падение скорости, частоты, температуры
 *   quick  <каталог> <метка>         cpu1, cpuN, mem, lat, ramp, io подряд + строка CSV
 *   csvhead                          заголовок CSV
 *
 * Программа ничего не меняет в системе: пишет только временный файл в <каталог> (удаляется) и пытается
 * сбросить кэш страниц (drop_caches; без root молча пропускается).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define MAXCPU 16

static inline uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static void sleep_ms(unsigned ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	while (nanosleep(&ts, &ts) && errno == EINTR)
		;
}

/* ---------- чтение sysfs ---------- */
static int rd_str(const char *path, char *buf, size_t n)
{
	FILE *f = fopen(path, "r");
	if (!f) { buf[0] = 0; return -1; }
	if (!fgets(buf, (int)n, f)) buf[0] = 0;
	fclose(f);
	buf[strcspn(buf, "\r\n")] = 0;
	return 0;
}

static long rd_long(const char *path, long dflt)
{
	char b[64];
	if (rd_str(path, b, sizeof b) || !b[0]) return dflt;
	return strtol(b, NULL, 10);
}

static int ncpu_online(void)
{
	long n = sysconf(_SC_NPROCESSORS_ONLN);
	if (n < 1) n = 1;
	if (n > MAXCPU) n = MAXCPU;
	return (int)n;
}

static long cpu_cur_khz(int cpu)
{
	char p[96];
	snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", cpu);
	return rd_long(p, -1);
}

static long battery_temp_dc(void) { return rd_long("/sys/class/power_supply/battery/temp", -1000); }

static void fmt_dc(long dc, char *out, size_t n)
{
	if (dc == -1000) snprintf(out, n, "н/д");
	else snprintf(out, n, "%.1f C", dc / 10.0);
}

static long hottest_zone_mc(void)
{
	long best = -1;
	for (int i = 0; i < 40; i++) {
		char p[96];
		snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/temp", i);
		long v = rd_long(p, -1000000);
		if (v == -1000000) continue;
		/* зоны то в милли-, то в целых градусах: приводим к милли-градусам */
		if (v > -200 && v < 200) v *= 1000;
		if (v > best && v < 200000) best = v;
	}
	return best;
}

static void active_sched(char *out, size_t n)
{
	char b[256];
	out[0] = 0;
	if (rd_str("/sys/block/mmcblk0/queue/scheduler", b, sizeof b)) return;
	char *l = strchr(b, '['), *r = l ? strchr(l, ']') : NULL;
	if (l && r) { *r = 0; snprintf(out, n, "%s", l + 1); }
}

/* ---------- список ядер ---------- */
static int parse_cpus(const char *s, int *cpus)
{
	int n = 0;
	while (*s && n < MAXCPU) {
		char *e;
		long a = strtol(s, &e, 10), b = a;
		if (e == s) break;
		if (*e == '-') { s = e + 1; b = strtol(s, &e, 10); }
		for (long c = a; c <= b && n < MAXCPU; c++) cpus[n++] = (int)c;
		s = (*e == ',') ? e + 1 : e;
		if (*e != ',' && *e) break;
	}
	return n;
}

static void pin_self(int cpu)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	sched_setaffinity(0, sizeof set, &set);
}

/* ---------- рабочая нагрузка CPU ---------- */
static volatile uint64_t g_sink;

static inline uint64_t spin_chunk(uint64_t x, int n)
{
	/* целочисленная цепочка: умножение + xorshift, зависимости между итерациями (не векторизуется) */
	for (int i = 0; i < n; i++) {
		x ^= x << 13; x ^= x >> 7; x ^= x << 17;
		x = x * 0x9E3779B97F4A7C15ull + (uint64_t)i;
	}
	return x;
}

#define CHUNK 20000

struct cpuarg {
	int pin;               /* -1 = не привязывать */
	volatile int *stop;
	uint64_t iters;        /* выполнено чанков */
};

static void *cpu_thread(void *p)
{
	struct cpuarg *a = p;
	uint64_t x = 88172645463325252ull ^ (uint64_t)(uintptr_t)a;
	if (a->pin >= 0) pin_self(a->pin);
	while (!*a->stop) {
		x = spin_chunk(x, CHUNK);
		a->iters++;
	}
	g_sink += x;
	return NULL;
}

/* secs секунд; nthreads потоков; pins = список ядер или NULL. Возвращает Мопс/с (миллионов итераций цепочки) */
static double run_cpu(double secs, int nthreads, const int *pins)
{
	pthread_t th[MAXCPU];
	struct cpuarg arg[MAXCPU];
	volatile int stop = 0;
	if (nthreads > MAXCPU) nthreads = MAXCPU;
	for (int i = 0; i < nthreads; i++) {
		arg[i].pin = pins ? pins[i] : -1;
		arg[i].stop = &stop;
		arg[i].iters = 0;
	}
	uint64_t t0 = now_ns();
	for (int i = 0; i < nthreads; i++) pthread_create(&th[i], NULL, cpu_thread, &arg[i]);
	sleep_ms((unsigned)(secs * 1000));
	stop = 1;
	uint64_t total = 0;
	for (int i = 0; i < nthreads; i++) { pthread_join(th[i], NULL); total += arg[i].iters; }
	double el = (now_ns() - t0) / 1e9;
	return (double)total * CHUNK / el / 1e6;
}

/* ---------- память ---------- */
static double bench_memcpy(size_t mb)
{
	size_t n = mb << 20;
	char *a = malloc(n), *b = malloc(n);
	if (!a || !b) { free(a); free(b); return -1; }
	memset(a, 1, n); memset(b, 2, n);
	double best = 0;
	for (int r = 0; r < 4; r++) {
		uint64_t t0 = now_ns();
		memcpy(b, a, n);
		double el = (now_ns() - t0) / 1e9;
		g_sink += b[r * 4096];
		double mbs = (double)mb / el;
		if (mbs > best) best = mbs;
	}
	free(a); free(b);
	return best;
}

static double bench_chase(size_t mb)
{
	size_t cnt = (mb << 20) / 64;
	uint32_t *next = NULL;
	char *buf = NULL;
	if (posix_memalign((void **)&buf, 64, cnt * 64)) return -1;
	next = malloc(cnt * sizeof *next);
	if (!next) { free(buf); return -1; }
	for (size_t i = 0; i < cnt; i++) next[i] = (uint32_t)i;
	uint64_t s = 12345;
	for (size_t i = cnt - 1; i > 0; i--) { /* Саттоло: один цикл по всем элементам */
		s = s * 6364136223846793005ull + 1442695040888963407ull;
		size_t j = (size_t)((s >> 33) % i);
		uint32_t t = next[i]; next[i] = next[j]; next[j] = t;
	}
	for (size_t i = 0; i < cnt; i++) *(uint32_t *)(buf + (size_t)i * 64) = next[i];
	uint32_t p = 0;
	long steps = 4000000;
	uint64_t t0 = now_ns();
	for (long i = 0; i < steps; i++) p = *(volatile uint32_t *)(buf + (size_t)p * 64);
	double ns = (double)(now_ns() - t0) / steps;
	g_sink += p;
	free(buf); free(next);
	return ns;
}

/* ---------- диск ---------- */
static void drop_caches(void)
{
	sync();
	int fd = open("/proc/sys/vm/drop_caches", O_WRONLY);
	if (fd >= 0) { if (write(fd, "3", 1) < 0) { } close(fd); }
}

struct ioarg {
	const char *path;
	size_t fsize;
	int direct;
	double secs;
	uint64_t ops;
	uint64_t seed;
};

static void *randread_thread(void *p)
{
	struct ioarg *a = p;
	int fd = open(a->path, O_RDONLY | (a->direct ? O_DIRECT : 0));
	if (fd < 0) return NULL;
	void *buf;
	if (posix_memalign(&buf, 4096, 4096)) { close(fd); return NULL; }
	uint64_t s = a->seed;
	size_t blocks = a->fsize / 4096;
	uint64_t t0 = now_ns(), lim = (uint64_t)(a->secs * 1e9);
	while (now_ns() - t0 < lim) {
		s = s * 6364136223846793005ull + 1442695040888963407ull;
		off_t off = (off_t)((s >> 33) % blocks) * 4096;
		if (pread(fd, buf, 4096, off) != 4096) break;
		a->ops++;
	}
	free(buf);
	close(fd);
	return NULL;
}

static double randread(const char *path, size_t fsize, int direct, int threads, double secs)
{
	pthread_t th[8];
	struct ioarg a[8];
	if (threads > 8) threads = 8;
	for (int i = 0; i < threads; i++) {
		a[i] = (struct ioarg){ path, fsize, direct, secs, 0, 0x1234567ull + i * 7919 };
		pthread_create(&th[i], NULL, randread_thread, &a[i]);
	}
	uint64_t ops = 0;
	for (int i = 0; i < threads; i++) { pthread_join(th[i], NULL); ops += a[i].ops; }
	return (double)ops / secs; /* IOPS */
}

struct iores { double seqw, seqr, rr1, rr4, rw_iops, rw_ms; int direct; };

static int bench_io(const char *dir, size_t mb, struct iores *r)
{
	char path[512];
	snprintf(path, sizeof path, "%s/.kknx-io.tmp", dir);
	struct statvfs sv;
	if (statvfs(dir, &sv) == 0 && (double)sv.f_bavail * sv.f_frsize < (double)mb * 2.2 * 1048576) {
		fprintf(stderr, "io: мало места в %s, пропуск\n", dir);
		return -1;
	}
	size_t chunk = 1 << 20;
	char *buf;
	if (posix_memalign((void **)&buf, 4096, chunk)) return -1;
	uint64_t x = 99;
	for (size_t i = 0; i < chunk; i += 8) { x = x * 6364136223846793005ull + 1; memcpy(buf + i, &x, 8); } /* несжимаемые данные */

	/* 1) последовательная запись (через кэш + fdatasync в конце: измеряет путь записи до накопителя) */
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) { perror("io: open"); free(buf); return -1; }
	uint64_t t0 = now_ns();
	for (size_t i = 0; i < mb; i++)
		if (write(fd, buf, chunk) != (ssize_t)chunk) { perror("io: write"); break; }
	fdatasync(fd);
	r->seqw = (double)mb / ((now_ns() - t0) / 1e9);
	close(fd);

	drop_caches();
	{
		int rfd = open(path, O_RDONLY);
		if (rfd >= 0) { posix_fadvise(rfd, 0, 0, POSIX_FADV_DONTNEED); close(rfd); }
	}

	/* 2) последовательное чтение (O_DIRECT, если файловая система позволяет) */
	r->direct = 1;
	fd = open(path, O_RDONLY | O_DIRECT);
	if (fd < 0) { r->direct = 0; fd = open(path, O_RDONLY); }
	t0 = now_ns();
	for (size_t i = 0; i < mb; i++)
		if (pread(fd, buf, chunk, (off_t)i * chunk) != (ssize_t)chunk) break;
	r->seqr = (double)mb / ((now_ns() - t0) / 1e9);
	close(fd);

	/* 3) случайное чтение 4К: 1 поток и 4 потока */
	drop_caches();
	r->rr1 = randread(path, mb << 20, r->direct, 1, 3.0);
	drop_caches();
	r->rr4 = randread(path, mb << 20, r->direct, 4, 3.0);

	/* 4) случайная запись 4К с O_DSYNC (как SQLite/журналы): IOPS и средняя задержка */
	fd = open(path, O_WRONLY | O_DSYNC);
	if (fd >= 0) {
		void *wb;
		if (!posix_memalign(&wb, 4096, 4096)) {
			memset(wb, 0x5a, 4096);
			uint64_t s = 777, w0 = now_ns();
			int ops = 0;
			while (now_ns() - w0 < 3000000000ull && ops < 6000) {
				s = s * 6364136223846793005ull + 1442695040888963407ull;
				off_t off = (off_t)((s >> 33) % ((mb << 20) / 4096)) * 4096;
				if (pwrite(fd, wb, 4096, off) != 4096) break;
				ops++;
			}
			double el = (now_ns() - w0) / 1e9;
			r->rw_iops = ops / el;
			r->rw_ms = ops ? el * 1000.0 / ops : 0;
			free(wb);
		}
		close(fd);
	}
	unlink(path);
	free(buf);
	return 0;
}

/* ---------- задержка пробуждения ---------- */
static int cmp_u32(const void *a, const void *b)
{
	uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
	return (x > y) - (x < y);
}

struct latres { double p50, p90, p99, max; };

static void *busy_thread(void *p)
{
	volatile int *stop = p;
	uint64_t x = 1;
	while (!*stop) x = spin_chunk(x, 2000);
	g_sink += x;
	return NULL;
}

static void bench_lat(double secs, int load, struct latres *r)
{
	pthread_t th[MAXCPU];
	volatile int stop = 0;
	if (load > MAXCPU) load = MAXCPU;
	for (int i = 0; i < load; i++) pthread_create(&th[i], NULL, busy_thread, (void *)&stop);
	sleep_ms(150); /* дать нагрузке раскрутиться */
	size_t cap = (size_t)(secs * 1000) + 100, n = 0;
	uint32_t *v = malloc(cap * sizeof *v);
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	uint64_t end = now_ns() + (uint64_t)(secs * 1e9);
	while (now_ns() < end && n < cap) {
		ts.tv_nsec += 1000000; /* 1 мс */
		if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
		struct timespec t1;
		clock_gettime(CLOCK_MONOTONIC, &t1);
		int64_t late = ((int64_t)t1.tv_sec - ts.tv_sec) * 1000000000ll + (t1.tv_nsec - ts.tv_nsec);
		if (late < 0) late = 0;
		v[n++] = (uint32_t)(late > 4000000000ll ? 4000000000ll : late) / 1000;
	}
	stop = 1;
	for (int i = 0; i < load; i++) pthread_join(th[i], NULL);
	if (n) {
		qsort(v, n, sizeof *v, cmp_u32);
		r->p50 = v[n * 50 / 100]; r->p90 = v[n * 90 / 100];
		r->p99 = v[n * 99 / 100]; r->max = v[n - 1];
	} else memset(r, 0, sizeof *r);
	free(v);
}

/* ---------- разгон после простоя ---------- */
static double ramp_once(int cpu, uint64_t work_iters, double hot_ms, double *first_ms, int verbose)
{
	if (cpu >= 0) pin_self(cpu);
	sleep_ms(600); /* простой: governor сбрасывает частоту, ядро уходит в сон */
	uint64_t x = 7, t_start = now_ns();
	double settle = -1, dur[64];
	for (int b = 0; b < 64; b++) {
		uint64_t t0 = now_ns();
		x = spin_chunk(x, (int)work_iters);
		dur[b] = (now_ns() - t0) / 1e6;
		if (settle < 0 && dur[b] <= hot_ms * 1.25) settle = (now_ns() - t_start) / 1e6;
	}
	g_sink += x;
	*first_ms = dur[0];
	if (verbose) {
		printf("  пачки (мс, ожидание на плато %.2f):", hot_ms);
		for (int b = 0; b < 12; b++) printf(" %.1f", dur[b]);
		printf("\n");
	}
	return settle < 0 ? (now_ns() - t_start) / 1e6 : settle;
}

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* возвращает медиану времени выхода на плато (мс) и среднее время первой пачки */
static void bench_ramp(int cpu, double *settle_med, double *first_med, int verbose)
{
	if (cpu >= 0) pin_self(cpu);
	/* калибровка: сколько итераций занимает ~3 мс на горячем CPU */
	uint64_t x = 3;
	uint64_t t0 = now_ns();
	while (now_ns() - t0 < 400000000ull) x = spin_chunk(x, CHUNK);
	uint64_t t1 = now_ns();
	uint64_t cnt = 0;
	while (now_ns() - t1 < 100000000ull) { x = spin_chunk(x, CHUNK); cnt++; }
	g_sink += x;
	double iters_per_ms = (double)cnt * CHUNK / 100.0;
	uint64_t work = (uint64_t)(iters_per_ms * 3.0);
	if (work < 1000) work = 1000;
	double hot_ms = 3.0;
	double st[5], fm[5];
	for (int i = 0; i < 5; i++) st[i] = ramp_once(cpu, work, hot_ms, &fm[i], verbose && i == 0);
	qsort(st, 5, sizeof st[0], cmp_d);
	qsort(fm, 5, sizeof fm[0], cmp_d);
	*settle_med = st[2];
	*first_med = fm[2];
}

/* ---------- сводка окружения ---------- */
static void env_line(char *out, size_t n)
{
	struct utsname u;
	uname(&u);
	char g0[32] = "", g4[32] = "", sch[32] = "";
	rd_str("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", g0, sizeof g0);
	rd_str("/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor", g4, sizeof g4);
	active_sched(sch, sizeof sch);
	snprintf(out, n, "%s,%s,%s,%s", u.release, g0, g4, sch);
}

static void print_csvhead(void)
{
	printf("label,kernel,gov0,gov4,iosched,bat_t0_dC,bat_t1_dC,cpu1_Mops,cpuN_Mops,cpuBig_Mops,cpuLit_Mops,memcpy_MBs,chase_ns,"
	       "lat_p50_us,lat_p90_us,lat_p99_us,lat_max_us,ramp_first_ms,ramp_settle_ms,"
	       "io_seqw_MBs,io_seqr_MBs,io_rr4k_q1_iops,io_rr4k_q4_iops,io_rw4k_sync_iops,io_rw4k_sync_ms,io_direct\n");
}

static int cmd_quick(const char *dir, const char *label)
{
	int n = ncpu_online();
	char env[256];
	env_line(env, sizeof env);
	long bt0 = battery_temp_dc();
	printf("== kknx-bench quick: %s ==\n%s\n", label, env);
	{
		char tb[24];
		fmt_dc(bt0, tb, sizeof tb);
		printf("батарея до: %s, cpu0=%ld кГц, cpu4=%ld кГц\n", tb, cpu_cur_khz(0), cpu_cur_khz(4));
	}

	double c1 = run_cpu(3, 1, NULL);
	printf("cpu 1 поток:       %8.1f Мопс/с\n", c1);
	double cn = run_cpu(4, n, NULL);
	printf("cpu все (%d):      %8.1f Мопс/с\n", n, cn);
	double cb = -1, cl = -1;
	if (n >= 8) {
		int big[4] = { 0, 1, 2, 3 }, lit[4] = { 4, 5, 6, 7 };
		cb = run_cpu(3, 4, big);
		cl = run_cpu(3, 4, lit);
		printf("cpu ядра 0-3:     %8.1f Мопс/с\ncpu ядра 4-7:     %8.1f Мопс/с\n", cb, cl);
	}
	double mc = bench_memcpy(64), ch = bench_chase(64);
	printf("memcpy 64 МБ:     %8.0f МБ/с\nслучайный доступ: %8.1f нс\n", mc, ch);

	struct latres lr;
	bench_lat(4, n, &lr);
	printf("задержка пробуждения при %d потоках нагрузки (мкс): p50=%.0f p90=%.0f p99=%.0f max=%.0f\n", n, lr.p50, lr.p90, lr.p99, lr.max);

	double rs, rf;
	bench_ramp(-1, &rs, &rf, 1);
	printf("разгон после простоя: первая пачка %.1f мс, выход на плато за %.0f мс (медиана из 5)\n", rf, rs);

	struct iores io;
	memset(&io, 0, sizeof io);
	int ioerr = bench_io(dir, 192, &io);
	if (!ioerr)
		printf("диск (%s): seq запись %.0f МБ/с, seq чтение %.0f МБ/с, rand4K чтение q1 %.0f IOPS, q4 %.0f IOPS, rand4K запись+sync %.0f IOPS (%.2f мс)\n",
		       io.direct ? "O_DIRECT" : "через кэш", io.seqw, io.seqr, io.rr1, io.rr4, io.rw_iops, io.rw_ms);
	long bt1 = battery_temp_dc();
	{
		char tb[24];
		fmt_dc(bt1, tb, sizeof tb);
		long hz = hottest_zone_mc();
		char zb[24];
		if (hz < 0) snprintf(zb, sizeof zb, "н/д"); else snprintf(zb, sizeof zb, "%.1f C", hz / 1000.0);
		printf("батарея после: %s, самая горячая зона: %s\n", tb, zb);
	}

	printf("CSV,%s,%s,%ld,%ld,%.1f,%.1f,%.1f,%.1f,%.0f,%.1f,%.0f,%.0f,%.0f,%.0f,%.1f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.2f,%d\n",
	       label, env, bt0, bt1, c1, cn, cb, cl, mc, ch, lr.p50, lr.p90, lr.p99, lr.max, rf, rs,
	       io.seqw, io.seqr, io.rr1, io.rr4, io.rw_iops, io.rw_ms, io.direct);
	return 0;
}

static int cmd_sustain(int minutes)
{
	int n = ncpu_online();
	const char *se = getenv("KKNX_SLICE");
	double slice = se ? atof(se) : 20.0;
	if (slice < 1) slice = 20.0;
	int slices = (int)(minutes * 60 / slice);
	if (slices < 3) slices = 3;
	printf("== sustain: %d мин, %d потоков, слайсы по %.0f с ==\n", minutes, n, slice);
	printf("  t,с  Мопс/с   cpu0,МГц cpu4,МГц  батарея,C  горячая зона,C\n");
	double first = 0, last = 0, sum_first3 = 0, sum_last3 = 0, mx_t = 0;
	double v[512];
	if (slices > 512) slices = 512;
	for (int i = 0; i < slices; i++) {
		double m = run_cpu(slice, n, NULL);
		v[i] = m;
		long f0 = cpu_cur_khz(0), f4 = cpu_cur_khz(4), bt = battery_temp_dc(), hz = hottest_zone_mc();
		printf("%5.0f %8.1f %9ld %8ld %9.1f %12.1f\n", (i + 1) * slice, m, f0 / 1000, f4 / 1000, bt == -1000 ? 0.0 : bt / 10.0, hz / 1000.0);
		fflush(stdout);
		if (hz / 1000.0 > mx_t) mx_t = hz / 1000.0;
	}
	for (int i = 0; i < 3 && i < slices; i++) { sum_first3 += v[i]; sum_last3 += v[slices - 1 - i]; }
	first = sum_first3 / 3; last = sum_last3 / 3;
	printf("Среднее первых 3 слайсов: %.1f, последних 3: %.1f, изменение: %+.1f%%, макс. температура зоны: %.1f C\n",
	       first, last, (last - first) * 100.0 / first, mx_t);
	return 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc < 2) {
		fprintf(stderr, "использование: %s cpu|mem|io|lat|ramp|sustain|quick|csvhead ...\n(см. комментарий в начале исходника)\n", argv[0]);
		return 2;
	}
	const char *c = argv[1];
	int n = ncpu_online();
	if (!strcmp(c, "csvhead")) { print_csvhead(); return 0; }
	if (!strcmp(c, "cpu")) {
		double secs = argc > 2 ? atof(argv[2]) : 5;
		if (secs <= 0) secs = 5;
		int pins[MAXCPU], cnt = n;
		int *pp = NULL;
		if (argc > 3) {
			if (strpbrk(argv[3], "-,")) { cnt = parse_cpus(argv[3], pins); pp = pins; }
			else { cnt = atoi(argv[3]); if (cnt < 1) cnt = 1; }
		}
		if (cnt < 1) { fprintf(stderr, "cpu: пустой список ядер\n"); return 2; }
		printf("cpu: %.0f с, %d потоков%s: %.1f Мопс/с\n", secs, cnt, pp ? " (привязаны)" : "", run_cpu(secs, cnt, pp));
		return 0;
	}
	if (!strcmp(c, "mem")) {
		size_t mb = argc > 2 ? (size_t)atoi(argv[2]) : 64;
		if (mb < 4) mb = 4;
		printf("memcpy %zu МБ: %.0f МБ/с\nслучайный доступ (%zu МБ): %.1f нс\n", mb, bench_memcpy(mb), mb, bench_chase(mb));
		return 0;
	}
	if (!strcmp(c, "io")) {
		if (argc < 3) { fprintf(stderr, "io: нужен каталог\n"); return 2; }
		struct iores r; memset(&r, 0, sizeof r);
		size_t mb = argc > 3 ? (size_t)atoi(argv[3]) : 192;
		if (mb < 16) mb = 16;
		if (bench_io(argv[2], mb, &r)) return 1;
		printf("диск (%s, файл %zu МБ): seq запись %.0f МБ/с, seq чтение %.0f МБ/с, rand4K чтение q1 %.0f IOPS, q4 %.0f IOPS, rand4K запись+sync %.0f IOPS (%.2f мс)\n",
		       r.direct ? "O_DIRECT" : "через кэш", mb, r.seqw, r.seqr, r.rr1, r.rr4, r.rw_iops, r.rw_ms);
		return 0;
	}
	if (!strcmp(c, "lat")) {
		double secs = argc > 2 ? atof(argv[2]) : 5;
		int load = argc > 3 ? atoi(argv[3]) : n;
		struct latres r;
		bench_lat(secs, load, &r);
		printf("задержка пробуждения при %d потоках нагрузки (мкс): p50=%.0f p90=%.0f p99=%.0f max=%.0f\n", load, r.p50, r.p90, r.p99, r.max);
		return 0;
	}
	if (!strcmp(c, "ramp")) {
		int cpu = argc > 2 ? atoi(argv[2]) : -1;
		double rs, rf;
		bench_ramp(cpu, &rs, &rf, 1);
		printf("разгон после простоя (ядро %d): первая пачка %.1f мс, выход на плато за %.0f мс\n", cpu, rf, rs);
		return 0;
	}
	if (!strcmp(c, "sustain")) return cmd_sustain(argc > 2 ? atoi(argv[2]) : 6);
	if (!strcmp(c, "quick")) {
		if (argc < 4) { fprintf(stderr, "quick: нужны <каталог> <метка>\n"); return 2; }
		return cmd_quick(argv[2], argv[3]);
	}
	fprintf(stderr, "неизвестная команда: %s\n", c);
	return 2;
}
