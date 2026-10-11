#ifndef CIPHER_TEST_KDF_H
#define CIPHER_TEST_KDF_H

/// 시험 프로세스의 SQLCipher 기본 키 유도 반복 수. 제품·rekordbox는 SQLCipher 4 기본값 256,000번을 쓴다.
#define DJC_TEST_KDF_ITER 1
#define DJC_TEST_KDF_ITER_TEXT "1"

/// 장치가 넣을 반복 수. 시험이 이 함수를 불러야 링커가 장치(constructor)를 시험 묶음에 넣는다.
int djc_test_kdf_iterations(void);

/// 환경(`이름=값` 배열, NULL로 끝남)에 시험 기본 변수 밖의 `DJC_` 변수가 있으면 1. 그때 장치는 기본값을 그대로 둔다.
/// 그런 변수는 rekordbox가 만든 사본을 읽는 실험 재현 시험이나 앱·djc에 넘길 사본을 만드는 캡처 시험을 켠다.
int djc_test_kdf_keeps_default(char *const *environment);

/// 이 프로세스의 환경으로 본 `djc_test_kdf_keeps_default`
int djc_test_kdf_process_keeps_default(void);

/// 프로세스 시작 때 장치가 반복 수를 낮췄으면 1, 기본값을 그대로 뒀으면 0.
int djc_test_kdf_lowered(void);

#endif
