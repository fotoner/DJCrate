---
name: verify-change
description: 작업이 끝났다고 말하기 전에 바꾼 것을 확인하고 보고할 때 쓴다. 검증 단계(편집 중 --quick → 작업 끝 scripts/check.sh --changed → 합치기 전 전체), --changed 출력·끝 요약 읽는 법, 넓히기·재사용, 보고 형식이 있다.
---

# 바꾼 것 확인하고 보고하기

작업이 끝났다고 말하기 전에 바꾼 것을 확인하고 보고하는 절차다.

## 단계

| 단계 | 언제 | 명령 | 보는 것 |
|---|---|---|---|
| 편집 중 | 시험을 쓰고 고칠 때마다 | `scripts/check.sh --quick --filter '^DJCDomainTests\.LoopPlannerTests/'` | 그 시험의 빨강 → 초록 |
| 작업 끝 | "됐다"고 말하기 전 한 번 | `scripts/check.sh --changed` | 바꾼 파일에 닿는 시험·검사 전부 통과 |
| 합치기 전·CI | `dev`에 합치기 직전 한 번, PR·`main` CI | `scripts/check.sh` | 릴리스 빌드·번역·전체 시험·커버리지(쓰기 80%·코어 60%) |
| 특수 | SQLCipher 초기화·`CipherLab`·cold-open | `scripts/check.sh --stress` | `.claude/rules/cipher.md` |

- 편집 중 필터는 Suite 하나나 시험 하나로 좁힌다.
- 타깃 이름으로 앵커하면(`'^<타깃>\.<Suite>/'`) 그 타깃의 시험만 돈다.
- `Tests`처럼 거의 모든 시험에 맞는 필터로 전체를 대신하지 않는다.
- 로컬 전체 검사는 사용자 요청, `dev` 합치기 직전, `--changed`가 넓힐 때만 돌린다.

## 작업 끝 확인 순서

1. 파트 워크트리처럼 `dev`와의 merge-base가 작업 시작점이 아니면, 작업 전에 `git write-tree`로 시작 트리를 뜬다.
2. 무거운 실행이 다른 작업과 겹칠 수 있으면 명령을 `lockf /tmp/djc-heavy.lock`으로 감싼다. 예: `lockf /tmp/djc-heavy.lock scripts/check.sh --changed`.
3. `scripts/check.sh --changed`를 돌린다. 1에서 뜬 트리가 있으면 `--base <트리 해시>`를 준다.
   - 이 명령과 `scripts/test-check.py`는 2분을 넘기 쉽다. Bash 도구 기본 timeout은 120초다. 그래서 배경으로 돌린다. 앞에서 돌릴 때는 timeout을 600초로 준다.
4. 출력 끝의 `── 검사 요약 ──` 블록을 읽는다. 읽는 법은 아래 "끝 요약 읽기"에 있다.
5. 종료 코드 3이나 4가 나오면 바로 멈춘다. 그 사실을 사용자에게 알린다.
6. 요약 끝에 `⚠ 남은 필수 검사: …`가 있으면 그 검사를 돌린다. 돌리지 않으면 돌리지 않았다고 보고한다.
7. 아래 "보고 형식"대로 보고한다.

## `--changed`가 하는 일

- 바뀐 파일은 기준과의 차이에 추적 안 된 파일을 더한 것이다. 기준은 `--base <rev>`이고, 없으면 `dev`와의 merge-base다.
- 처음 몇 줄에 고른 범위, 이유(파일 → 규칙 → Suite), 필터가 나온다.
- 범위를 미리 보려면 `python3 scripts/affected-tests.py --files <경로…>`를 돌린다. `--json`을 주면 기계용 출력이 나온다.
- 도는 순서는 아래와 같다. 문서만 바뀌면 빌드·시험 없이 가벼운 검사만 돈다.
  1. Swift 변경이면 `scripts/check-imports.py`
  2. 소스 타깃 전체 빌드. 앱·CLI를 컴파일할 수 없으면 실패한다.
  3. 고른 시험 타깃 빌드
  4. 고른 시험
  5. 조건부 검사: 번역, 쓰기 그룹 커버리지, `check-docs.py`, `test-harness.py`, `test-check.py`
- 쓰기 커버리지 그룹 파일(예: `RekordboxWriter*`, `Usb/Write/`)을 바꾸면 쓰기 그룹 80%를 잰다. 세 시험 타깃을 통째로 돌아 약 5분 걸린다.
- 아래 경우에는 전체를 돈다. 이때 `▸ 전체 검사로 넓힙니다: <이유>`를 낸다.
  - `Package.swift`나 `Package.resolved`가 바뀜
  - `scripts/check.sh`나 `.github/**`가 바뀜
  - 규칙 밖 파일이 바뀜
  - 고른 Suite가 절반을 넘음
- `Tests/Support/**`와 Suite 없는 시험 도우미를 바꾸면 그 시험 타깃 전체를 돈다.
- `Sources/djc/**`·`Sources/DJCAdapters/**`를 바꾸면 djcTests 전체를 돈다.
- 하네스만 바꾸면 넓히지 않는다. 그때는 `check-docs.py`와 `test-harness.py` 두 검사만 돈다. 하네스는 `scripts/hooks/**`·`.claude/**`와 `test-harness.py`·`check-docs.py`다.
- 잘못 묶은 인자는 종료 코드 2로 끝난다. 예: `--changed --filter`, `--changed` 없는 `--base`, `--changed --stress`.
- 안전 장치는 모든 모드에 그대로다. 종료 코드 3은 실제 rekordbox 파일이 바뀌었다는 뜻이다. 4는 DJCrate 사용자 폴더·로그 폴더·환경설정이 바뀌었다는 뜻이다.
- 같은 작업 트리·모드·필터의 통과 기록이 있으면 다시 돌리지 않는다. 그때는 `재사용: <로그 폴더>`만 낸다.
- 같은 작업 트리의 전체 검사 통과는 `--changed`만 대신한다. `--quick`은 대신하지 않는다.
- 다시 돌리려면 `--no-reuse`를 준다. stress는 늘 다시 돈다.
- `⚠ 남은 필수 검사: …`는 `--changed`가 대신하지 않는 검사다(예: `--stress`).
- Suite 이름 변경, Suite 삭제, 파일 이동 뒤에는 `scripts/test-map.txt`도 고친다. 지도에 없는 Suite나 어느 파일에도 맞지 않는 `when`이 있으면 종료 코드 2로 끝난다.

## 끝 요약 읽기

출력 끝의 `── 검사 요약 ──` 블록만 보면 된다. 블록에는 아래가 있다.

- 단계별 `✔`/`✘`와 초
- `✔ 통과: <모드> … 시험 N개` 또는 `✘ 실패: … 종료코드 N`
- 실패한 시험과 첫 오류 줄(최대 10개)
- 마지막 줄 `로그: <로그 폴더>`

실패를 더 보려면 그 폴더의 단계 로그(예: `test.log`, `debug-build.log`)에서 실패한 시험 ID로 grep한다. 빌드·시험 원문은 화면에 나오지 않는다. 원문을 보려면 `DJC_CHECK_VERBOSE=1`을 준다.

## 실패하면

1. 실패한 시험의 원인을 고친다.
2. 그 Suite를 `--quick`으로 돌려 초록을 본다.
3. 다시 `--changed`를 돌린다.

- 시험을 지워서 실패를 없애지 않는다. 기대값을 느슨하게 해서 없애지도 않는다.
- 고칠 수 없는 실패는 그대로 보고한다.
- 바꾼 것과 관계없어 보이는 실패(예: 부하, 순서)는 같은 Suite만 다시 돌린다. 그 결과(통과·실패 횟수)를 그대로 적는다.

## 보고 형식

1. 바꾼 것: 파일과 동작을 짧게 적는다.
2. 확인한 것: 아래를 적는다.
   - 실행한 명령 그대로
   - 고른 필터와 이유 요약. 넓혔으면 그 이유
   - 통과·실패 수, 종료 코드, 로그 폴더
   - 재사용이면 재사용한 로그 폴더
   - 앱 자가 테스트나 디스크 이미지 확인을 했으면 그 통과 줄
3. 남은 것: 돌리지 않은 검사와 그 이유, 사용자에게 물을 것을 적는다.

추측으로 "통과할 것"이라고 쓰지 않는다. 돌리지 않은 것은 돌리지 않았다고 쓴다.
