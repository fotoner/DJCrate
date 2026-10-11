# 기여 안내

DJCrate 개발에 참여하는 사람을 위한 안내다. macOS 27 이상과 Swift 6.2 툴체인(Xcode)이 필요하다.

```bash
swift build                                        # 디버그 빌드
scripts/build-app.sh                               # dist/DJCrate.app 만들기
scripts/check.sh --quick --filter '^DJCDomainTests\.LoopPlannerTests/'   # 고치는 동안: Suite 하나
scripts/check.sh --changed                         # 작업 끝·PR·dev 합치기 전: 바꾼 파일에 닿는 시험·검사만
scripts/check.sh                                   # 릴리스 전·요청: 빌드·번역 누락·전체 시험·커버리지 목표
```

`--changed`는 아래처럼 동작한다.

- 처음 몇 줄에 고른 시험과 이유를 낸다.
- `Package.swift`·`scripts/check.sh`·`.github/**`가 바뀌면 전체 검사로 넓힌다. 규칙 밖 파일이 바뀌어도 넓힌다.
- PR·`dev` 푸시 CI도 `--changed`만 돈다. 전체 검사는 릴리스(`main`·`release/*`) CI가 돈다. `--changed`가 놓친 회귀는 그때 잡힌다.
- 같은 작업 트리에서 이미 통과했으면 `재사용: <로그 폴더>`만 낸다. 다시 돌리려면 `--no-reuse`를 준다.

검증 단계와 각 모드가 하는 일은 [AGENTS.md의 검증](AGENTS.md#검증)과 [CI 문서](docs/ci.md#로컬-검증-운영)에 있다.

## 화면 문구

새 화면 문구나 고친 화면 문구가 있으면 `swift scripts/i18n.swift sync`를 돌린다. 그 뒤 영어·일본어 번역을 채운다([다국어 규칙](docs/i18n.md)).

영어 번역이 빠지면 영어와 그 밖의 언어 사용자에게 한국어가 보인다. 그래서 `check.sh`가 이것을 막는다.

## rekordbox 쓰기 시험

- rekordbox 쓰기 시험은 사본으로만 한다.
- `DJC_REKORDBOX_DIR=<사본 폴더>`와 `DJC_HOME=$(mktemp -d)`를 지정한다.
- 사본의 `share/PIONEER/USBANLZ`도 심볼릭 링크로 두지 않는다. 실제 파일로 복사한다.
- 앱 자가 테스트에도 임시 `DJC_HOME`을 지정한다.
- 라이브 DB, 분석 파일, 음원에는 쓰지 않는다.

## 이슈와 PR

- 이슈를 만들 때와 고를 때는 [이슈 관리 규칙](docs/issues.md)을 따른다.
- 브랜치·커밋은 [AGENTS.md의 저장소 규칙](AGENTS.md#저장소-규칙)을 따른다.
- PR은 `dev`를 대상으로 연다.
- PR에는 변경 내용과 실행한 확인 명령·결과를 적는다. rekordbox 쓰기 경로를 바꿨다면 사본 자가 테스트 결과도 적는다.
- 아래 셋은 [AGENTS.md의 안전 불변식](AGENTS.md#안전-불변식)을 따른다.
  - rekordbox 규칙 확인 방법
  - 외부 코드·문서와 제3자 고지
  - 내보내는 파일의 칸 단위 작성

## 앱 아이콘

1. 앱 아이콘은 Xcode 27의 `actool`로 `Assets/AppIcon.icon`을 컴파일한다.
2. 전경 SVG를 바꿀 때는 `swift scripts/make-icon.swift`로 다시 만든다.
3. Icon Composer에서 배경과 레이어 순서를 확인한다.
4. Icon Composer에서 기본·다크·모노 외관을 확인한다.

모서리와 반사 효과는 시스템이 입힌다. 그래서 원본에 그리지 않는다.

## 데이터 폴더와 개발용 명령

- DJCrate 데이터 폴더의 배치는 [구조 문서의 데이터 폴더](docs/architecture.md#데이터-폴더)에 있다. 이 폴더에는 초안·스냅샷과 백업·캐시가 있다.
- 환경 변수는 [CLI 문서의 환경 변수](docs/cli.md#환경-변수)에 있다. 개발에 쓰는 것은 아래와 같다.
  - `DJC_HOME`
  - `DJC_REKORDBOX_DIR`
  - `DJC_DB`
  - `DJC_IDLE_SECONDS`
  - `DJC_LANG`
- 스냅샷·백업·DB 사본에는 rekordbox 클라우드 토큰이 들어 있다. 커밋·이슈·로그에 넣지 않는다.
- 규칙 확인과 쓰기 시험에 쓰는 `djc` 명령은 [CLI 문서의 쓰기 명령](docs/cli.md#쓰기-명령사본에만)에 있다. 이 명령은 사본에만 쓴다.
- 소리·실제 화면·반영 전 과정은 디버그 빌드의 앱 자가 테스트로 확인한다. 인자와 조건은 [앱 자가 테스트 스킬](.claude/skills/app-selftest/SKILL.md)에 있다.

## 메뉴·단축키 손 확인

디버그 앱을 `DJC_HOME=<임시 폴더> DJC_REKORDBOX_DIR=<사본 폴더> DJC_DB=<사본 DB> .build/debug/DJCrate`로 연다. 사본은 분석 파일까지 실제로 복사한 것을 쓴다.

1. 파일, 보기, rekordbox, 덱, 도움말 메뉴의 항목과 조합 단축키를 본다.
2. 곡 선택, 반영 대기, 쓰기 중의 활성 상태를 본다.
3. 사이드바를 숨긴다. ⌘⇧E로 반영 확인 창을 연 뒤 취소한다.
4. ⌘I와 ⌃⌘I가 같은 태그 편집기를 여닫는지 본다.
5. 설정에서 재생·핫큐 키를 바꾼다.
6. 덱 메뉴와 단축키 창 안내가 새 키를 따라가는지 본다.
7. 새 키를 한 번 누르면 동작이 한 번만 일어나는지 본다.
8. 검색창·설정·단축키 창에서는 덱 키가 끼어들지 않는지 본다.
9. 키를 원래대로 돌린다.
10. 보기 › 툴바 사용자화를 라이트·다크에서 연다.
11. 도움말 › DJCrate 단축키를 라이트·다크에서 연다.

덱 메뉴의 수식키 없는 키는 안내다. 실제 입력은 KeyRouter가 받는다.
