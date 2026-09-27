#!/usr/bin/env python3
"""합성 명령만으로 검사 스크립트의 실패·파이프·취소·로그 보존을 확인한다."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).with_name("check.sh")
CASES = {
    "debug-fail": 23, "release-fail": 24, "translation-fail": 25,
    "test-fail": 26, "coverage-fail": 27, "pipe-fail": 28,
    "low-coverage": 1, "empty-coverage": 1, "ok": 0, "split-output": 0, "empty-output": 0, "partial-output": 0,
    "term": 143, "int": 130, "int-group": 130,
}
CANCELLATIONS = {"term", "int", "int-group"}
HASHING = "-Xswiftc -enable-incremental-file-hashing"
DEBUG = f"build --build-tests --enable-code-coverage {HASHING}"
RELEASE = "build -c release --product DJCrate"
TRANSLATIONS = f"scripts/i18n.swift check --enable-code-coverage {HASHING}"
TEST = f"test --skip-build --enable-code-coverage {HASHING}"
PARTITIONS = {
    "coverage-only": (["--coverage"], "ok", 0, [DEBUG, TRANSLATIONS, TEST]),
    "release-only": (["--release"], "ok", 0, [RELEASE]),
    "coverage-no-release": (["--coverage"], "release-fail", 0, [DEBUG, TRANSLATIONS, TEST]),
    "coverage-debug-fail": (["--coverage"], "debug-fail", 23, [DEBUG]),
    "coverage-translation-fail": (["--coverage"], "translation-fail", 25, [DEBUG, TRANSLATIONS]),
    "coverage-test-fail": (["--coverage"], "test-fail", 26, [DEBUG, TRANSLATIONS, TEST]),
    "coverage-threshold-fail": (["--coverage"], "low-coverage", 1, [DEBUG, TRANSLATIONS, TEST]),
    "release-build-fail": (["--release"], "release-fail", 24, [RELEASE]),
    "invalid-mode": (["--unknown"], "ok", 2, []),
    "extra-argument": (["--coverage", "--release"], "ok", 2, []),
}


def prepare(root):
    (root / "scripts").mkdir()
    (root / "bin").mkdir()
    (root / ".build/out/Products/Debug/FakeTests.xctest/Contents/MacOS").mkdir(parents=True)
    shutil.copy(SOURCE, root / "scripts/check.sh")
    (root / "bin/swift").write_text(f"#!{sys.executable}\n" + r'''
import os, pathlib, subprocess, sys, time
args = sys.argv[1:]
mode = os.environ["CASE"]
root = pathlib.Path.cwd()
with open("calls.txt", "a") as log:
    log.write(" ".join(args) + "\n")
if args[0] == "build" and "-c" not in args:
    if mode == "empty-output":
        sys.exit(0)
    if mode == "partial-output":
        os.write(1, b"stdout\n")
        os.write(2, b"stderr\n")
        os.write(1, "개행 없는 마지막".encode())
        sys.exit(0)
print("합성 출력: " + " ".join(args), flush=True)
if mode == "debug-fail" and args[0] == "build" and "-c" not in args:
    flag = root / "failed-once"
    if not flag.exists():
        flag.touch()
        sys.exit(23)
if mode == "split-output" and args[0] == "build" and "-c" not in args:
    os.write(1, b"\xe2")
    time.sleep(0.3)
    os.write(1, b"\x98\x83\n")
if mode == "release-fail" and "-c" in args:
    sys.exit(24)
if mode == "translation-fail" and args[0] == "scripts/i18n.swift":
    sys.exit(25)
if mode in ("term", "int", "int-group") and args[0] == "build":
    child = subprocess.Popen(["/bin/sleep", "60"])
    (root / "child.pid").write_text(str(child.pid))
    print("취소 전 출력", flush=True)
    child.wait()
if args[0] == "test":
    if mode == "test-fail":
        print("error: 합성 테스트 실패", flush=True)
        sys.exit(26)
    print("✔ Test run with 1 test passed after 0.1 seconds.")
''')
    (root / "bin/xcrun").write_text(r'''#!/bin/sh
[ "$CASE" = coverage-fail ] && exit 27
[ "$CASE" = empty-coverage ] && exit 0
if [ "$CASE" = low-coverage ]; then missed=99; else missed=5; fi
printf 'RekordboxKit/RekordboxWriter.swift 0 0 0 0 0 0 100 %s 95%%\n' "$missed"
printf 'DJCDomain/Cue.swift 0 0 0 0 0 0 100 %s 95%%\n' "$missed"
''')
    (root / "bin/tee").write_text('''#!/bin/sh
[ "$CASE" = pipe-fail ] && exit 28
exec /usr/bin/tee "$@"
''')
    (root / "bin/sleep").write_text('''#!/bin/sh
if [ "$CASE" = split-output ] && [ "$1" = 30 ]; then
    exec /bin/sleep 0.1
fi
exec /bin/sleep "$@"
''')
    for executable in (root / "bin").iterdir():
        executable.chmod(0o755)


def check_case(case, expected):
    with tempfile.TemporaryDirectory(prefix="djc-check-contract-") as directory:
        root = Path(directory)
        prepare(root)
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE=case)
        env.pop("DJC_CHECK_LOG_ROOT", None)
        with (root / "output.log").open("w") as output:
            process = subprocess.Popen(
                ["/bin/zsh", str(root / "scripts/check.sh")], cwd=root, env=env,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
            )
            try:
                if case in CANCELLATIONS:
                    deadline = time.monotonic() + 10
                    while not (root / "child.pid").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    assert (root / "child.pid").exists(), "취소할 자식이 시작되지 않음"
                    if case == "int-group":
                        os.killpg(process.pid, signal.SIGINT)
                    else:
                        process.send_signal(signal.SIGTERM if case == "term" else signal.SIGINT)
                code = process.wait(timeout=10)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        content = (root / "output.log").read_text()
        errors = []
        if case in CANCELLATIONS:
            child = int((root / "child.pid").read_text())
            try:
                os.kill(child, 0)
                os.kill(child, signal.SIGKILL)
                errors.append("취소 후 자식이 남음")
            except ProcessLookupError:
                pass
        if code != expected:
            errors.append(f"종료코드 {code}, 기대값 {expected}")
        if "시작" not in content or "종료" not in content:
            errors.append("단계 시간 누락")
        runs = list((root / ".build/check-logs").glob("run.*"))
        if len(runs) != 1:
            errors.append("실행별 로그 폴더 누락")
        else:
            run = runs[0]
            if (run / "exit-code.txt").read_text().strip() != str(expected):
                errors.append("보존한 종료코드 불일치")
            if len((run / "timings.tsv").read_text().splitlines()) < 2:
                errors.append("단계별 시간 파일 누락")
            if case not in {"pipe-fail", "empty-output", "partial-output"} and "합성 출력" not in (run / "debug-build.log").read_text():
                errors.append("원래 명령 출력 누락")
            if case in CANCELLATIONS and "취소 전 출력" not in (run / "debug-build.log").read_text():
                errors.append("취소 전 로그 유실")
            if case == "empty-output" and (run / "debug-build.log").read_bytes() != b"":
                errors.append("빈 원문 출력이 바뀜")
            if case == "partial-output":
                original = "stdout\nstderr\n개행 없는 마지막"
                if (run / "debug-build.log").read_text() != original or original not in content:
                    errors.append("stdout/stderr 순서나 개행 없는 마지막 출력 유실")
        if case == "split-output" and ("☃" not in content or "▸ 진행:" not in content):
            errors.append("나뉜 UTF-8 출력이나 진행 알림 유실")
        calls = (root / "calls.txt").read_text().splitlines()
        if case == "debug-fail" and len(calls) != 1:
            errors.append("실패 뒤에도 다음 명령 실행")
        if case == "ok" and (
            calls != [DEBUG, RELEASE, TRANSLATIONS, TEST]
        ):
            errors.append("디버그·테스트 빌드 공유 누락")
        assert not errors, ", ".join(errors) + "\n" + content


def check_partition(arguments, case, expected, expected_calls):
    with tempfile.TemporaryDirectory(prefix="djc-check-partition-") as directory:
        root = Path(directory)
        prepare(root)
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE=case)
        env.pop("DJC_CHECK_LOG_ROOT", None)
        result = subprocess.run(
            ["/bin/zsh", str(root / "scripts/check.sh"), *arguments], cwd=root, env=env,
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == expected, f"종료코드 {result.returncode}, 기대값 {expected}\n{result.stdout}"
        calls_file = root / "calls.txt"
        calls = calls_file.read_text().splitlines() if calls_file.exists() else []
        assert calls == expected_calls, f"검사 범위 불일치: {calls}"
        if expected_calls:
            run, = (root / ".build/check-logs").glob("run.*")
            assert (run / "exit-code.txt").read_text().strip() == str(expected), "종료코드 보존 누락"
            if arguments == ["--coverage"] and expected == 0:
                assert "목표 80%" in result.stdout and "목표 60%" in result.stdout, "커버리지 목표 검사 누락"


failures = 0
for case, expected in CASES.items():
    try:
        check_case(case, expected)
        print(f"✔ {case}")
    except (AssertionError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        failures += 1
        print(f"✘ {case}: {error}")
for name, arguments in PARTITIONS.items():
    try:
        check_partition(*arguments)
        print(f"✔ {name}")
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        failures += 1
        print(f"✘ {name}: {error}")
total = len(CASES) + len(PARTITIONS)
print(f"검사 스크립트 회귀: {total}개 중 {total - failures}개 통과")
sys.exit(bool(failures))
