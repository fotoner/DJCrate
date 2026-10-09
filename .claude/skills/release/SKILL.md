---
name: release
description: DJCrate 앱을 빌드해 설치하거나(/Applications) 배포용 ZIP·태그 Release를 준비할 때 사람이 부르는 절차. 앱이 켜져 있으면 끄기 전에 묻는다.
disable-model-invocation: true
---

# 앱 설치·배포

앱 설치와 배포 준비의 절차다. 정본은 `docs/releasing.md`다. 이 스킬은 순서와 확인할 점만 모은다.

출시 버전, 커밋, 태그는 관리자가 정한다. 에이전트는 태그와 Release를 만들지 않는다.

## 로컬 설치

1. DJCrate가 켜져 있는지 본다(`pgrep -x DJCrate`).
2. **켜져 있으면 끄기 전에 사용자에게 묻는다.**
3. 같은 checkout의 빌드·시험이 끝났는지 본다.
4. `scripts/build-app.sh --install`을 돌린다. 출력은 파일로 받는다.
5. 끝 줄과 종료 코드를 확인한다.
6. 명령, 종료 코드, 설치한 버전(`CFBundleShortVersionString`·`CFBundleVersion`)을 보고한다.

`scripts/build-app.sh --install`은 릴리스 빌드, 번들, 로컬 서명을 거쳐 `/Applications/DJCrate.app`에 설치한다.

## 배포 준비(태그 전)

1. 대상 커밋에서 전체 검사 `scripts/check.sh`를 통과시킨다. 배포 워크플로도 이 검사를 다시 돈다.
2. 시험용 패키지를 만든다: `scripts/build-app.sh --version 0.0.0 --package`.
3. `dist/`의 ZIP과 `.zip.sha256`을 확인한다(`shasum -a 256 -c`).
4. 압축 해제한 번들의 서명을 확인한다(`codesign --verify --deep --strict`).
5. 같은 번들의 버전과 아키텍처를 확인한다.
6. 같은 번들에 `LICENSE`와 `THIRD_PARTY_NOTICES.md`가 있는지 본다.
7. 워크플로를 바꿨으면 `zsh -n scripts/build-app.sh`와 `actionlint .github/workflows/release.yml`을 돌린다.

태그 푸시(`vX.Y.Z`)부터 Release 업로드까지는 `.github/workflows/release.yml`이 한다. 태그와 푸시는 사용자가 요청할 때만 한다.

## 하지 않는 것

- Gatekeeper를 끄지 않는다. 다운로드 격리 속성도 지우지 않는다.
- 개발용 데이터와 라이브러리 사본을 앱·ZIP에 넣지 않는다.
- 기존 Release를 덮어쓰지 않는다. 태그를 새로 만들지 않는다.
- 재실행 실패는 관리자가 본다.
