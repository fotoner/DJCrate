// SQLCipher 모듈 머리가 Foundation을 가져오므로 Objective-C 파일로 둔다(C로는 모듈을 만들지 못한다).
#include "CipherTestKDF.h"

#include <SQLCipher/sqlite3.h>
#include <crt_externs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int djc_test_kdf_iterations(void) { return DJC_TEST_KDF_ITER; }

static int lowered = 0;

int djc_test_kdf_lowered(void) { return lowered; }

/// 시험 기본 환경(scripts/check.sh·CI·시험 재료가 주는 변수). 이 밖의 `DJC_` 변수는 실험·캡처 시험을 켤 수 있다.
static const char *const harmless[] = {
    "DJC_HOME", "DJC_REKORDBOX_DIR", "DJC_LANG", "DJC_TEST_DEFAULTS_PREFIX", "DJC_CIPHER_STRESS", "DJC_SIGN_IDENTITY", NULL,
};

int djc_test_kdf_keeps_default(char *const *environment) {
    for (char *const *entry = environment; entry && *entry; entry++) {
        if (strncmp(*entry, "DJC_", 4) != 0) continue;
        if (strncmp(*entry, "DJC_CHECK_", 10) == 0) continue;
        size_t length = strcspn(*entry, "=");
        int known = 0;
        for (const char *const *name = harmless; *name; name++) {
            if (strlen(*name) == length && strncmp(*entry, *name, length) == 0) { known = 1; break; }
        }
        if (!known) return 1;
    }
    return 0;
}

int djc_test_kdf_process_keeps_default(void) { return djc_test_kdf_keeps_default(*_NSGetEnviron()); }

/// 시험 묶음이 올라올 때(시험·스레드가 시작되기 전) 한 번, 이 프로세스의 SQLCipher 기본 키 유도 반복 수를 낮춘다.
/// 시험 시간의 대부분이 PBKDF2 256,000번이었다. 반복 수 말고 키·KDF·HMAC·쪽 크기는 SQLCipher 4 기본값 그대로다.
/// 이 대상은 시험 타깃만 링크한다(Package.swift). 앱·djc는 기본값 그대로 연다.
/// 실험 사본(rekordbox가 256,000번으로 만든 파일)을 읽거나 앱·djc에 넘길 사본을 만드는 시험이 켜졌으면 기본값을 그대로 둔다.
__attribute__((constructor)) static void djc_test_lower_kdf_iter(void) {
    if (djc_test_kdf_process_keeps_default()) return;
    sqlite3 *db = NULL;
    char *error = NULL;
    if (sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK ||
        sqlite3_exec(db, "PRAGMA cipher_default_kdf_iter = " DJC_TEST_KDF_ITER_TEXT, NULL, NULL, &error) != SQLITE_OK) {
        // 조용히 넘어가면 시험이 느린 채로 통과한다. 시험(CipherTestKDFTests)도 값을 보지만 여기서 바로 알린다.
        fprintf(stderr, "CipherTestKDF: 기본 키 유도 반복 수를 낮추지 못했습니다: %s\n", error ? error : (db ? sqlite3_errmsg(db) : "open"));
        sqlite3_free(error);
        sqlite3_close_v2(db);
        abort();
    }
    sqlite3_close_v2(db);
    lowered = 1;
}
