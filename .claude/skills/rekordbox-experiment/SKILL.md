---
name: rekordbox-experiment
description: rekordbox가 실제로 무엇을 쓰는지 알아내야 할 때(새 쓰기 경로·막아 둔 조건 풀기·새 rekordbox 버전 허용) 사용자에게 rekordbox에서 편집을 부탁하고 전후 스냅샷을 비교하는 절차.
disable-model-invocation: true
---

# rekordbox 실험 부탁하고 비교하기

사용자에게 rekordbox 편집을 부탁한 뒤 전후 스냅샷을 비교하는 절차다.

정본 절차는 `docs/rekordbox-internals.md` "새 쓰기 경로를 여는 방법"이다. 이 스킬은 사용자에게 부탁하는 방법과 비교·기록 순서를 더한다.

rekordbox 규칙은 rekordbox 화면에서 편집한 결과 파일을 비교해서만 알아낸다. 실행 파일은 분석하지 않는다(AGENTS.md "안전 불변식").

## 1. 에이전트가 먼저 하는 것

1. 무엇을 확인하려는지 한 줄로 정한다.
2. 비교할 표·칸·분석 파일 태그 목록을 `docs/rekordbox-internals.md`에서 찾아 둔다.
3. rekordbox가 켜져 있으면 사용자에게 먼저 끄라고 한다.
4. rekordbox가 꺼진 상태에서 편집 전 스냅샷을 뜬다: `djc snapshot`.
5. 스냅샷 사본 경로를 적어 둔다.
6. 실험에 쓸 곡 후보를 사본에서 고른다(`djc search … --db <사본>`).
7. 사용자에게는 곡 제목만 보인다. 경로와 곡 수는 적지 않는다.

에이전트가 할 수 있는 일은 사용자에게 묻지 않는다. 스냅샷, 비교, 사본 재현은 에이전트가 직접 한다.

## 2. 사용자에게 부탁하기

부탁은 할 일 단계로 쓴다. 한 번에 한 실험만 부탁한다. 단계마다 무엇을 누르는지까지 쓴다.

```
rekordbox 실험을 부탁드립니다(약 N분).
1. rekordbox를 켭니다.
2. 컬렉션에서 "<곡 제목>"을 찾아 <무엇을> <어떻게> 바꿉니다(예: 핫큐 A를 1.000초에 찍음).
3. (필요하면) 두 번째 곡 "<곡 제목>"에도 같은 편집을 합니다.
4. rekordbox를 완전히 종료합니다(rekordboxAgent도 꺼질 때까지 기다림).
5. 끝나면 "끝"이라고 알려 주세요. 실제로 바꾼 곡 이름과 값을 적어 주시면 비교가 정확해집니다.
```

- rekordbox가 조작마다 바로 쓰는 표는 단계마다 비교할 수 있다. 이때는 `djc lab playlist-watch --out <임시 폴더>`를 켜 둔다.
- `djc lab playlist-watch`는 읽기 전용 복사만 한다.
- 단계마다 비교할 때는 사용자에게 단계 사이마다 알려 달라고 부탁한다.
- 결과 파일 이름(예: 바뀐 분석 파일)을 알면 비교가 빠르다. 사용자가 본 것이 있으면 함께 받는다.

## 3. 비교

1. 새 스냅샷을 뜬다: `djc snapshot --force`. rekordbox가 꺼진 뒤에는 `--force` 없이 뜬다.
2. DB 차이를 본다: `djc lab db-diff`.
3. 바뀐 표·칸·usn 순서를 적는다.
4. 칸은 `djc lab sql <사본.db> "SELECT …"`로 확인한다. 이 명령은 읽기 전용이다. `agentRegistry` 질의는 막는다.
5. 분석 파일 차이를 본다. 그 곡의 `share/PIONEER/USBANLZ/…`를 전후 사본에서 비교한다. 필요하면 `djc lab` 실험 명령을 쓴다.
6. 사본 재현을 한다. 실험 전 사본에 DJCrate로 같은 편집을 쓴다(예: `djc lab loop-repro --old … --new … --ids … --work <임시 폴더>`).
7. 재현 결과를 칸마다 비교한다. 난수 ID·UUID, 시각, 변경 번호 값은 뺀다.
8. 외래 키는 가리키는 값으로 비교한다.

## 4. 일치하면

1. `Tests/RekordboxKitTests`에 골든 시험을 먼저 쓴다. 실험 곡과 날짜를 주석으로 단다.
2. 빨간색을 본다.
3. 막아 둔 조건을 푼다(`.claude/rules/rekordbox-write.md`).
4. `docs/rekordbox-internals.md`에 규칙을 적는다. 날짜, 실험 곡, 확인 방법을 함께 적는다.

## 5. 일치하지 않으면

1. 막은 채로 둔다.
2. 무엇이 달랐는지와 다음 실험안을 이슈 댓글로 남긴다(`needs:experiment` 라벨, `docs/issues.md`).

## 기록할 때

- 스냅샷과 DB 사본에는 토큰이 있다.
- 비교 결과를 이슈나 로그에 옮길 때 값과 경로를 넣지 않는다. 곡 수도 넣지 않는다.
