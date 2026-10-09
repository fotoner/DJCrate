---
name: usb-image-check
description: USB 쓰기(내보내기·수정·옮기기·되돌리기·회복)를 실물 USB 없이 임시 폴더의 FAT32 디스크 이미지로 끝까지 확인할 때 쓴다. djc lab usb-image·usb-write-check·usb-tree·usb-diff·usb-rebuild·usb-commit-crash 순서와 hdiutil info 뒷정리가 있다.
---

# USB 디스크 이미지로 쓰기 전 과정 확인

USB 쓰기 전 과정을 실물 USB 없이 디스크 이미지로 확인하는 절차다.

USB 쓰기 시험은 `djc lab usb-image`로 만든 디스크 이미지에만 한다. 이 Mac에 꽂힌 실제 볼륨(`/Volumes/*`)에는 쓰지 않는다. 실제 볼륨은 나열과 `usb-info` 읽기만 한다.

규칙은 `.claude/rules/usb-write.md`, 형식은 `docs/usb-internals.md`, 명령 인자는 `docs/cli.md`에 있다.

## 준비

1. rekordbox와 rekordboxAgent를 끈다. 켜져 있으면 이미지 명령이 실행을 거부한다. 만들기, 붙이기, 채우기, 쓰기 시험이 모두 그렇다.
2. 이미지, 마운트 지점, 출력 폴더는 모두 임시 폴더 아래에 둔다. 밖에 두면 `UsbScratchPath`가 거부한다.
3. `DJC_HOME`도 임시 폴더로 준다. 주지 않으면 USB 백업·세션·스냅샷이 실제 DJCrate 데이터 폴더에 쌓인다.
4. 같은 checkout의 빌드와 겹치지 않게 `swift build`를 먼저 끝낸다.
5. 처음 한 번 작업 폴더를 만든다. 그 절대 경로를 적어 둔다(아래 첫 블록).
6. **호출마다 맨 앞에서 변수를 다시 정한다.** 비었으면 멈추게 한다(아래 둘째 블록).
7. djc는 변수(`$D`)로 부르지 않는다. `.build/debug/djc`를 그대로 쓴다.

셸 변수와 `export`는 다음 Bash 호출에 남지 않는다. 그래서 5·6단계가 필요하다. 7단계는 훅이 명령을 알아보게 하려는 것이다.

```bash
# 처음 한 번
W=$(mktemp -d); mkdir -p "$W/home" "$W/mnt"; echo "작업 폴더: $W"
```

```bash
# 호출마다 맨 앞(경로는 위에서 적은 절대 경로)
W=<작업 폴더>; : "${W:?작업 폴더를 적으세요}"; export DJC_HOME="$W/home"; : "${DJC_HOME:?}"
```

아래 "순서"의 1~6단계는 단계마다 한 호출 안의 짧은 스크립트로 돌린다. 아래는 1단계의 예다.

```bash
W=<작업 폴더>; : "${W:?}"; export DJC_HOME="$W/home"; : "${DJC_HOME:?}"; L="$W/step1.log"
.build/debug/djc lab usb-image create "$W/a.dmg" > "$L" 2>&1 \
  && .build/debug/djc lab usb-image attach "$W/a.dmg" --mount "$W/mnt" >> "$L" 2>&1 \
  && .build/debug/djc lab usb-tree "$W/mnt" > "$W/before.txt" \
  && .build/debug/djc lab usb-write-check --volume "$W/mnt" >> "$L" 2>&1 \
  && .build/debug/djc usb-restore --volume "$W/mnt" >> "$L" 2>&1 \
  && .build/debug/djc lab usb-tree "$W/mnt" > "$W/after.txt"; echo "exit=$?"
diff "$W/before.txt" "$W/after.txt" && echo "트리 같음"; grep "USB 쓰기 시험 통과" "$L"
.build/debug/djc lab usb-image detach "$W/a.dmg"
```

## 명령

```bash
.build/debug/djc lab usb-image create|attach|detach|info <이미지>   # 임시 폴더 아래 FAT32 디스크 이미지(attach는 --mount <폴더>)
.build/debug/djc lab usb-image seed --image <이미지> --from <폴더>  # 붙인 이미지에 폴더 내용을 데이터만 복사
.build/debug/djc lab usb-tree <루트>                                # USB 트리(NFC 경로·크기·SHA-256, 마지막 줄 ._ 수)
.build/debug/djc lab usb-diff <A> <B> [--onelibrary|--device-library] [--files] [--mtime] [--anlz] [--ignore-anlz-folder] [--ignore-ids] [--skip …]   # 두 USB 폴더 비교(값·경로 없이, --mtime은 FAT 2초 단위)
.build/debug/djc lab usb-rebuild <USB 폴더> <출력 폴더>             # 읽은 모델로 DB 셋만 새 내보내기 모양으로 다시 만들기(usb-diff --ignore-ids로 비교)
.build/debug/djc lab usb-migrate-check <USB 폴더>                   # 두 형식이 있는 USB(골든 사본)의 pdb를 옮기기 변환해 그 USB의 OneLibrary와 칸 비교
.build/debug/djc lab usb-fields <USB 폴더> --out <파일.json>        # 두 리더가 읽은 칸을 해시로(외부 파서 대조 scripts/usb-parser-compare.py, docs/usb-internals.md §8.2)
.build/debug/djc lab usb-anlz-relocate <USB 사본> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]   # 기기 실험용: 한 곡의 분석 파일·DB 경로를 어긋나게(임시 폴더 사본에만)
.build/debug/djc lab usb-write-check --volume <마운트>              # 합성 묶음을 디스크 이미지에 써 보고 다시 붙여 검증
.build/debug/djc lab usb-commit-crash --image <빈 이미지> --repeat N  # 쓰는 도중 강제 분리 → 회복을 되풀이
```

## 순서

각 단계의 통과 줄과 종료 코드는 로그 파일에 받아 grep한다.

1. **쓰기·되돌리기**(위 예)
   1. `lab usb-image create`로 이미지를 만든다.
   2. `attach --mount <작업 폴더>/mnt`로 붙인다.
   3. `lab usb-tree`로 쓰기 전 트리를 받는다.
   4. `lab usb-write-check --volume <작업 폴더>/mnt`를 돌린다. "USB 쓰기 시험 통과" 줄을 본다.
   5. `usb-restore --volume <작업 폴더>/mnt`로 되돌린다.
   6. `lab usb-tree`가 쓰기 전과 같은지 본다.
   7. `detach`로 뗀다.
2. **강제 분리**: 붙이지 않은 빈 이미지로 `lab usb-commit-crash --image <이미지> --repeat N`을 돌린다. "N/N 파일마다 옛것 또는 새것, 회복 N/N" 줄을 본다.
3. **내보내기**: 분석 파일이 있는 로컬 사본이 필요하다. `--usb-selftest`가 만든 `$DJC_HOME/usb-selftest/local`을 쓴다. `PlaylistWriteFixtureCapture` 사본은 분석 파일이 없어 `analysisIncomplete`로 막힌다. 붙인 빈 이미지에 아래를 차례로 돌린다.
   1. `usb-export --dry-run`. 트리가 그대로인지 본다.
   2. `usb-export`. "결과: 썼습니다" 줄을 본다.
   3. `usb-info --json <마운트>`. 두 형식, `roundTripOK` true, 경고 없음을 본다.
   4. `lab usb-rebuild`
   5. `lab usb-diff … --ignore-ids`. "차이 0"을 본다.
4. **수정**: 내보낸 이미지에 아래를 차례로 돌린다.
   1. `usb-edit … --dry-run`. 트리가 그대로인지 본다.
   2. `usb-edit`. 편집별 결과 줄을 본다.
   3. `usb-info --json <마운트>`
   4. `lab usb-rebuild`와 `usb-diff --ignore-ids`. "차이 0"을 본다.
   5. `usb-restore`. 트리가 쓰기 전과 같은지 본다.
5. **옮기기**: Device Library만 채운 이미지(`lab usb-image seed`)에 아래를 차례로 돌린다.
   1. `usb-migrate --dry-run`. 트리가 그대로인지 본다.
   2. `usb-migrate`. "결과: 썼습니다" 줄을 본다. 원래 파일이 그대로인지 `lab usb-tree`로 본다.
   3. `usb-info --json <마운트>`. 두 형식, `roundTripOK` true, 경고 없음을 본다.
   4. `lab usb-rebuild`와 `usb-diff --ignore-ids`. "차이 0"을 본다.
   5. `usb-restore`. 트리가 옮기기 전과 같은지 본다.
6. **뒷정리**: 붙인 이미지를 모두 `detach`로 뗀다. 그 뒤 `hdiutil info`에 작업 폴더의 이미지가 남지 않았는지 본다.

시트·확인 창과 토스트·되돌리기 같은 앱 흐름은 디버그 앱 `--usb-selftest`로 본다(스킬 `app-selftest`). 앱 없이 같은 흐름을 보려면 `UsbSelfTestScenarioCapture`를 쓴다.

## 보고

- 단계마다 명령, 통과 줄(또는 실패 줄)과 수치, 종료 코드를 적는다.
- 마지막 `hdiutil info` 확인 결과를 적는다.
- 실물 USB·CDJ에서 확인하지 않은 것은 "기기에서 확인하지 않음"으로 남긴다.
