@AGENTS.md

# Claude Code

<!-- 유지 관리: 늘 실리는 맥락이다. Claude 전용 몇 줄만 두고 나머지는 AGENTS.md(모든 에이전트)·.claude/rules(경로별, 해당 파일을 열 때 자동으로 실림)·.claude/skills(절차)에 둔다. 훅·권한은 .claude/settings.json과 scripts/hooks/, 시험은 scripts/test-harness.py. -->

- 파일을 많이 읽는 일은 서브에이전트로 돌린다. 웹 조사와 다른 저장소 조사가 그런 일이다. 서브에이전트에게서는 결론만 가져온다.
- 리뷰는 `.claude/agents/reviewer.md`에 맡긴다.
- 긴 명령은 출력을 파일로 받는다(`> 로그 2>&1`). 그 뒤 끝 요약과 필요한 줄만 읽는다.
- 앱 자가 테스트는 스킬 `app-selftest`대로 `timeout`을 걸어 포그라운드로 돌린다.
- 완료 보고는 아래 순서로 짧게 쓴다(스킬 `verify-change`).
  1. 바꾼 것
  2. 확인한 것: 실행한 명령과 결과 수치
  3. 남은 것, 사용자에게 물을 것
