/*
 * standalone_main.c — non-libFuzzer run-once driver for the libvncserver fuzz harness.
 *
 * Reads ONE input file and feeds it to LLVMFuzzerTestOneInput exactly once. Linked against the
 * sanitized libvncserver build (FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION) plus fuzz_server.c, this
 * is the standalone reproducer (/mayhem/fuzz_server-standalone): same code path the libFuzzer
 * target exercises, no fuzzing-engine runtime.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size);

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "failed to open %s\n", argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) { fclose(f); return 3; }
    uint8_t *data = (uint8_t *)malloc((size_t)size ? (size_t)size : 1);
    if (!data) { fclose(f); return 3; }
    size_t got = size ? fread(data, 1, (size_t)size, f) : 0;
    fclose(f);
    LLVMFuzzerTestOneInput(data, got);
    free(data);
    return 0;
}
