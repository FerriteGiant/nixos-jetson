// Minimal STREAM-like DRAM bandwidth test (copy / scale / triad, 64 MiB
// arrays, best of N). Build & run on the Nano:
//   nix shell nixpkgs#gcc -c gcc -O2 -fopenmp -o /tmp/membw tools/membw.c && /tmp/membw
#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N (8 * 1024 * 1024) /* doubles per array = 64 MiB */
#define REPS 10

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(void) {
  double *a = malloc(N * sizeof *a), *b = malloc(N * sizeof *b),
         *c = malloc(N * sizeof *c);
#pragma omp parallel for
  for (long i = 0; i < N; i++) a[i] = 1.0, b[i] = 2.0, c[i] = 0.0;

  double best[3] = {1e9, 1e9, 1e9};
  for (int r = 0; r < REPS; r++) {
    double t = now();
#pragma omp parallel for
    for (long i = 0; i < N; i++) c[i] = a[i];
    t = now() - t; if (t < best[0]) best[0] = t;

    t = now();
#pragma omp parallel for
    for (long i = 0; i < N; i++) b[i] = 3.0 * c[i];
    t = now() - t; if (t < best[1]) best[1] = t;

    t = now();
#pragma omp parallel for
    for (long i = 0; i < N; i++) a[i] = b[i] + 3.0 * c[i];
    t = now() - t; if (t < best[2]) best[2] = t;
  }
  const char *name[3] = {"copy", "scale", "triad"};
  const double bytes[3] = {2.0 * N * 8, 2.0 * N * 8, 3.0 * N * 8};
  for (int k = 0; k < 3; k++)
    printf("%-6s %8.0f MB/s\n", name[k], bytes[k] / best[k] / 1e6);
  printf("threads %d, check %.1f\n", omp_get_max_threads(), a[N / 2]);
  return 0;
}
