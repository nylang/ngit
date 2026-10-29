// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/* Private provider fixture driver. Store/lock/publication acceptance belongs to Nyra.
 * Usage: origin revision repository-path export-path offline-flag
 * The fixture owns both explicit paths; neither is an ngit cache root. */
#include "git_bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--invalid")) {
    char buffer[512];
    memset(buffer, 0x5a, sizeof(buffer));
    if (ngit_hash_bytes("abc", 3, buffer, 64) != -3 || buffer[0] != 0x5a) {
      return 1;
    }
    if (ngit_hash_bytes("abc", 3, buffer, 65) != 64 ||
        strcmp(buffer, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") ||
        buffer[65] != 0x5a) {
      return 1;
    }
    if (ngit_prepare_repository(NULL, 1, NULL, 1, NULL, 1, 0, 1000) >= 0) {
      return 1;
    }
    if (ngit_prepare_repository("/x", 2, "/x", 2, "/x", 2, 0, 0) >= 0) {
      return 1;
    }
    if (ngit_export_snapshot("/x", 2, "x", 1, "/x", 2, "/x", 2, 0, 1000, NULL, 512) >= 0) {
      return 1;
    }
    memset(buffer, 0x5a, sizeof(buffer));
    if (ngit_export_snapshot("/x", 2, "x", 1, "/x", 2, "/x", 2, 0, 1000, buffer, 127) != -3 ||
        buffer[0] != 0x5a) {
      return 1;
    }
    return 0;
  }
  if (argc != 6) {
    return 2;
  }
  int offline = atoi(argv[5]);
  int prepared =
      ngit_prepare_repository(argv[1], (int)strlen(argv[1]), argv[3], (int)strlen(argv[3]), argv[3],
                              (int)strlen(argv[3]), offline, 1000);
  if (prepared < 0) {
    fprintf(stderr, "private Git preparation status %d\n", prepared);
    return 1;
  }
  char output[512] = {0};
  int result = ngit_export_snapshot(argv[1], (int)strlen(argv[1]), argv[2], (int)strlen(argv[2]),
                                    argv[3], (int)strlen(argv[3]), argv[4], (int)strlen(argv[4]),
                                    offline, 1000, output, sizeof(output));
  if (result < 0) {
    fprintf(stderr, "private Git export status %d\n", result);
    return 1;
  }
  fwrite(output, 1, (size_t)result, stdout);
  return 0;
}
