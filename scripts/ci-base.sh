#!/bin/bash
# CI의 --changed 비교 기준을 정한다(.github/workflows/check.yml이 부른다). GITHUB_OUTPUT에 더할 두 줄을 낸다.
#   base=<커밋> reason=      기준을 구했다
#   base=       reason=<글>  기준을 구할 수 없다. 워크플로는 전체 검사로 넓힌다(조용히 좁히지 않는다)
# 입력(환경 변수): EVENT(github.event_name), BASE_REF(PR 기준 브랜치), BEFORE(푸시 앞 끝), FORCED(강제 푸시면 true)
# PR은 체크아웃한 병합 커밋과 origin/<BASE_REF>의 merge-base(병합 커밋의 첫 부모)와 비교한다.
# 푸시는 앞 끝과 비교한다. 앞 끝이 지금 커밋의 조상이 아니면(강제 푸시·받은 기록에 없음) 비교하지 않는다.
set -u

base=""
reason=""
case "${EVENT:-}" in
    pull_request)
        if [[ -z "${BASE_REF:-}" ]]; then
            reason="PR 기준 브랜치를 모릅니다"
        elif ! base=$(git merge-base HEAD "origin/$BASE_REF" 2>/dev/null); then
            base=""
            reason="PR 기준 브랜치 origin/${BASE_REF}와의 merge-base를 구하지 못했습니다"
        fi ;;
    push)
        before=${BEFORE:-}
        if [[ "${FORCED:-}" == true ]]; then
            reason="강제 푸시라 앞 끝과 비교하지 않습니다"
        elif [[ -z "$before" || "$before" =~ ^0+$ ]]; then
            reason="새 브랜치라 앞 끝이 없습니다"
        elif ! git merge-base --is-ancestor "$before" HEAD 2>/dev/null; then
            reason="앞 끝 ${before:0:12}이(가) 지금 커밋의 조상이 아니거나 받은 기록에 없습니다"
        else
            base=$before
        fi ;;
    *)
        reason="${EVENT:-(빈 값)} 실행에는 비교 기준이 없습니다" ;;
esac
printf 'base=%s\nreason=%s\n' "$base" "$reason"
