#!/usr/bin/env python3
"""합성 명령만으로 검사 스크립트의 실패·파이프·취소·로그 보존을 확인한다."""
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).with_name("check.sh")
IMPORTS = Path(__file__).with_name("check-imports.py")
AFFECTED = Path(__file__).with_name("affected-tests.py")
CASES = {
    "debug-fail": 23, "release-fail": 24, "translation-fail": 25,
    "test-fail": 26, "coverage-fail": 27, "pipe-fail": 28,
    "low-coverage": 1, "empty-coverage": 1, "missing-write-file": 1, "write-subfolder": 0,
    "missing-write-name": 1, "missing-write-gate": 1, "missing-usb-write": 1, "few-write-files": 1, "ok": 0, "split-output": 0, "empty-output": 0, "partial-output": 0,
    "term": 143, "int": 130, "int-group": 130,
    "user-folder-write": 4, "log-folder-write": 4, "app-running-write": 0,
    "preferences-leak": 4, "preferences-leak-app-running": 4, "preferences-other-run": 0,
    "live-library-write": 3, "stale-profile": 1,
    # 전체 검사도 문서·훅 검사를 돈다(H3c: 시험 재료 폴더를 옮겨 rules paths가 깨졌는데 전체 검사가 통과했다).
    "docs-fail": 31, "harness-fail": 32, "prose-fail": 33,
    # 끝 요약에 옮기는 오류 줄에서 터미널 색·링크 시퀀스를 지운다(로그 원문은 그대로).
    "ansi-fail": 29,
}
# 화면에 원래 명령 출력을 그대로 흘리는(DJC_CHECK_VERBOSE=1) 경우. 기본은 요약 줄·실패 줄만 화면에 낸다.
VERBOSE_CASES = {"split-output", "partial-output"}
# 시험이 사용자 환경설정 폴더에 시험 설정 파일(plist)을 남기는 경우(adv4 T6). 이번 실행 접두사만 실패로 센다.
PREFERENCE_LEAKS = {
    "preferences-leak": "{prefix}deck.leak.plist",
    "preferences-leak-app-running": "{prefix}deck.leak.plist",
    "preferences-other-run": "djc-test-OTHER1-deck.leak.plist",
}
# 시험이 DJCrate 사용자 폴더·로그 폴더에 쓰는 경우(#218). 합성 HOME 아래만 쓴다.
LEAKS = {
    "user-folder-write": "Library/Application Support/DJCrate/waveforms/leak.json",
    "log-folder-write": "Library/Logs/DJCrate/audio.log",
    "app-running-write": "Library/Application Support/DJCrate/loudness.json",
}
CANCELLATIONS = {"term", "int", "int-group"}
DEBUG = "build --build-tests --enable-code-coverage"
RELEASE = "build -c release --product DJCrate"
TRANSLATIONS = "scripts/i18n.swift check --enable-code-coverage"
TEST = "test --skip-build --enable-code-coverage"
QUICK = TEST + " --filter SampleTests"
STRESS = TEST + " --filter CipherColdOpenTests"
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
    "quick-only": (["--quick", "--filter", "SampleTests"], "ok", 0, [DEBUG, QUICK]),
    "quick-no-release": (["--quick", "--filter", "SampleTests"], "release-fail", 0, [DEBUG, QUICK]),
    "quick-no-translations": (["--quick", "--filter", "SampleTests"], "translation-fail", 0, [DEBUG, QUICK]),
    "quick-no-coverage-report": (["--quick", "--filter", "SampleTests"], "coverage-fail", 0, [DEBUG, QUICK]),
    "quick-debug-fail": (["--quick", "--filter", "SampleTests"], "debug-fail", 23, [DEBUG]),
    "quick-test-fail": (["--quick", "--filter", "SampleTests"], "test-fail", 26, [DEBUG, QUICK]),
    "quick-pipe-fail": (["--quick", "--filter", "SampleTests"], "pipe-fail", 28, [DEBUG]),
    "quick-zero-tests": (["--quick", "--filter", "SampleTests"], "zero-tests", 1, [DEBUG, QUICK]),
    "quick-all-skipped": (["--quick", "--filter", "SampleTests"], "all-skipped", 1, [DEBUG, QUICK]),
    "quick-no-test-summary": (["--quick", "--filter", "SampleTests"], "no-test-summary", 1, [DEBUG, QUICK]),
    "quick-regex": (["--quick", "--filter", "SampleTests|OtherTests/edge.*"], "ok", 0,
                    [DEBUG, TEST + " --filter SampleTests|OtherTests/edge.*"]),
    "quick-dirty-metadata": (["--quick", "--filter", "SampleTests"], "dirty", 0, [DEBUG, QUICK]),
    "quick-repeat": (["--quick", "--filter", "SampleTests"], "repeat", 0, [DEBUG, QUICK]),
    "quick-no-reuse-first": (["--no-reuse", "--quick", "--filter", "SampleTests"], "ok", 0, [DEBUG, QUICK]),
    "quick-no-reuse-twice": (["--quick", "--filter", "SampleTests", "--no-reuse", "--no-reuse"], "ok", 2, []),
    "stress-repeat": (["--stress"], "repeat", 0, [DEBUG, STRESS]),
    "quick-missing-filter": (["--quick"], "ok", 2, []),
    "quick-missing-value": (["--quick", "--filter"], "ok", 2, []),
    "quick-empty-filter": (["--quick", "--filter", ""], "ok", 2, []),
    "quick-whitespace-filter": (["--quick", "--filter", " \t"], "ok", 2, []),
    "quick-option-value": (["--quick", "--filter", "--stress"], "ok", 2, []),
    "quick-extra-value": (["--quick", "--filter", "SampleTests", "OtherTests"], "ok", 2, []),
    "full-filter": (["--filter", "SampleTests"], "ok", 2, []),
    "stress-only": (["--stress"], "ok", 0, [DEBUG, STRESS]),
    "stress-zero-tests": (["--stress"], "zero-tests", 1, [DEBUG, STRESS]),
    "stress-fail": (["--stress"], "test-fail", 26, [DEBUG, STRESS]),
    "stress-extra-filter": (["--stress", "--filter", "SampleTests"], "ok", 2, []),
    "quick-stress-env-invalid": (["--quick", "--filter", "SampleTests"], "stress-env-invalid", 2, []),
    "full-stress-env-invalid": ([], "stress-env-invalid", 2, []),
    "stress-env-invalid": (["--stress"], "stress-env-invalid", 2, []),
    "stress-env-empty": (["--stress"], "stress-env-empty", 2, []),
    "stress-env-zero": (["--stress"], "stress-env-zero", 0, [DEBUG, STRESS]),
    "quick-env-zero": (["--quick", "--filter", "SampleTests"], "stress-env-zero", 0, [DEBUG, QUICK]),
    # 진행 줄 서브셸의 자식을 pgrep이 못 찾아도(경쟁) 고아 sleep이 출력 파이프를 붙들지 않는다(P1-5).
    "quick-pulse-orphan": (["--quick", "--filter", "SampleTests"], "pulse-orphan", 0, [DEBUG, QUICK]),
}


# 합성 저장소의 패키지 타깃(이름, 종류, 경로 — None이면 Sources/<이름>·Tests/<이름>). 모듈 경계 검사가 dump-package로 읽는다.
PREPARE_TARGETS = [
    ("SQLCipher", "binary", None),
    *((name, "regular", None) for name in ("DJCDomain", "DJCEnvironment", "DJCApplication", "RekordboxKit", "DJCStorage",
                                           "DJCAnalysis", "DJCAdapters", "DJCrate", "djc")),
    ("DJCrateExecutable", "executable", None), ("djcExecutable", "executable", None),
    ("DJCTestKit", "regular", "Tests/Support/Kit"), ("RekordboxFixtures", "regular", "Tests/Support/Fixtures"),
    ("PortTestKit", "regular", "Tests/Support/Ports"),
    *((name, "test", None) for name in ("DJCDomainTests", "RekordboxKitTests", "DJCAnalysisTests", "DJCStorageTests",
                                        "DJCApplicationTests", "DJCAdaptersTests", "djcTests", "DJCrateTests")),
]


def import_rules():
    """실제 check-imports.py의 예외 목록(합성 저장소의 자리 채움에 쓴다)"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_imports", IMPORTS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package_dump(targets):
    out = []
    for name, kind, path in targets:
        target = {"name": name, "type": kind, "dependencies": []}
        if path:
            target["path"] = path
        out.append(target)
    return json.dumps({"name": "DJCrate", "targets": out})


def prepare(root):
    (root / "scripts").mkdir()
    (root / "bin").mkdir()
    (root / ".build/out/Products/Debug/FakeTests.xctest/Contents/MacOS").mkdir(parents=True)
    for bundle in ("DJCDomainTests", "RekordboxKitTests", "djcTests"):
        (root / f".build/out/Products/Debug/{bundle}.xctest/Contents/MacOS").mkdir(parents=True)
    (root / "fake-index").write_text("합성 index")
    (root / ".build/out/Products/Debug/codecov").mkdir(parents=True)
    (root / ".build/out/Products/Debug/codecov/default.profdata").write_text("이전 실행의 프로파일")
    (root / "tree.txt").write_text("a" * 40 + "\n")
    shutil.copy(SOURCE, root / "scripts/check.sh")
    shutil.copy(IMPORTS, root / "scripts/check-imports.py")
    shutil.copy(AFFECTED, root / "scripts/affected-tests.py")
    (root / "scripts/import-debt.txt").write_text("# 빚 없음\n")
    # 모듈 경계 검사의 이름 예외(조립 지점 파일)·넓은 예외 폴더는 있어야 하고, 폴더 예외가 허용한 import는 쓰여야 한다(자리 채움).
    rules = import_rules()
    for relative in rules.ASSEMBLY_FILES:
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        (root / relative).write_text("import Foundation\n")
    for folder, modules in rules.BROAD_FOLDERS.items():
        (root / folder).mkdir(parents=True, exist_ok=True)
        (root / folder / "Placeholder.swift").write_text("".join(f"import {name}\n" for name in sorted(modules)))
    # 모듈 경계 검사가 타깃 이름·경로를 읽는 합성 패키지(dump-package는 가짜 swift가 dump.json을 낸다).
    (root / "Package.swift").write_text("// 합성 패키지\n")
    (root / "dump.json").write_text(package_dump(PREPARE_TARGETS))
    # 전체 검사가 함께 도는 문서·훅 검사(가짜): 부른 인자를 light-calls.txt에 남기고 CASE에 따라 실패한다.
    for name, code, failing in (("check-docs.py", 31, "docs-fail"), ("check-prose.py", 33, "prose-fail"),
                                ("test-harness.py", 32, "harness-fail")):
        (root / "scripts" / name).write_text(
            "import os, sys\n"
            f"open('light-calls.txt', 'a').write(' '.join(['{name}', *sys.argv[1:]]) + '\\n')\n"
            f"print('{name} 합성 출력')\n"
            f"sys.exit({code} if os.environ.get('CASE') == '{failing}' else 0)\n")
    (root / "bin/swift").write_text(f"#!{sys.executable}\n" + (r'''
import json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
mode = os.environ["CASE"]
root = pathlib.Path.cwd()
if args[:2] == ["package", "dump-package"]:
    print((root / "dump.json").read_text())
    sys.exit(0)
with open("env.txt", "a") as log:
    log.write(os.environ.get("DJC_HOME", "unset") + "\t" + os.environ.get("DJC_REKORDBOX_DIR", "unset") + "\n")
with open("calls.txt", "a") as log:
    log.write(" ".join(args) + "\n")
with open("stress-env.txt", "a") as log:
    log.write(os.environ.get("DJC_CIPHER_STRESS", "unset") + "\n")
with open("defaults-prefix.txt", "a") as log:
    log.write(os.environ.get("DJC_TEST_DEFAULTS_PREFIX", "unset") + "\n")
if mode == "pulse-orphan" and args[0] == "build":
    time.sleep(1.5)
if args[0] == "test" and "--enable-code-coverage" in args and mode != "stale-profile":
    profile = root / ".build/out/Products/Debug/codecov/default.profdata"
    profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text("합성 프로파일")
if args[0] == "test" and mode == "tree-moves":
    (root / "tree.txt").write_text("b" * 40 + "\n")
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
if mode == "ansi-fail" and args[0] == "build" and "-c" not in args:
    print("/x/UsbWriteHost.swift:65:69: \x1b[1;31merror: \x1b[1;39mmissing import of 'DJCStorage'\x1b[0;0m "
          "[#\x1b]8;;https://docs.swift.org/x\x1b\\MemberImportVisibility\x1b]8;;\x1b\\]", flush=True)
    print("   \x1b[0;36m|\x1b[0;0m `- \x1b[1;31merror: \x1b[1;39mclass property\x1b[0;0m", flush=True)
    sys.exit(29)
if mode == "translation-fail" and args[0] == "scripts/i18n.swift":
    sys.exit(25)
if mode in ("term", "int", "int-group") and args[0] == "build":
    child = subprocess.Popen(["/bin/sleep", "60"])
    (root / "child.pid").write_text(str(child.pid))
    print("취소 전 출력", flush=True)
    child.wait()
if args[0] == "test":
    leaks = json.loads(os.environ["LEAKS"])
    preference_leaks = json.loads(os.environ["PREFERENCE_LEAKS"])
    if mode in preference_leaks:
        name = preference_leaks[mode].format(prefix=os.environ["DJC_TEST_DEFAULTS_PREFIX"])
        leak = pathlib.Path(os.environ["HOME"]) / "Library/Preferences" / name
        leak.parent.mkdir(parents=True, exist_ok=True)
        leak.write_text("<plist/>")
    if mode in leaks:
        leak = pathlib.Path(os.environ["HOME"]) / leaks[mode]
        leak.parent.mkdir(parents=True, exist_ok=True)
        with open(leak, "a") as file:
            file.write("시험이 쓴 줄\n")
    if mode == "live-library-write":
        with open(pathlib.Path(os.environ["HOME"]) / "Library/Pioneer/rekordbox/master.db", "a") as file:
            file.write("시험이 쓴 바이트")
    if mode == "fail-once" and not (root / "failed-test-once").exists():
        (root / "failed-test-once").touch()
        print("error: 한 번만 실패", flush=True)
        sys.exit(26)
    if mode == "test-fail":
        print("✔ Test 통과한_시험() passed after 0.1 seconds.", flush=True)
        print("✘ Test 실패한_시험() recorded an issue at FooTests.swift:3:5: Expectation failed: 1 == 2", flush=True)
        print("error: 합성 테스트 실패", flush=True)
        sys.exit(26)
    if mode == "zero-tests":
        print("✔ Test run with 0 tests passed after 0.1 seconds.")
        sys.exit(0)
    if mode == "no-test-summary":
        sys.exit(0)
    if mode == "all-skipped":
        print("↷ Test synthetic() skipped.")
        print("✔ Test run with 1 test passed after 0.1 seconds.")
        sys.exit(0)
    print("✔ Test synthetic() passed after 0.1 seconds.")
    print("✔ Test run with 1 test passed after 0.1 seconds.")
'''))
    # 가짜 git: 바뀐 파일은 CHANGED(줄바꿈으로 나눔), 작업 트리 해시는 tree.txt. 부른 인자는 git-calls.txt에 남긴다.
    (root / "bin/git").write_text('''#!/bin/sh
echo "$*" >> git-calls.txt
case "$1" in
    rev-parse)
        if [ "$2" = --git-path ]; then echo "$PWD/fake-index"; else echo synthetic-head; fi ;;
    status) [ "$CASE" = dirty ] && echo ' M scripts/check.sh' ;;
    merge-base) echo synthetic-base ;;
    diff) [ "$2" = --name-only ] && [ -n "$CHANGED" ] && printf '%s\\n' "$CHANGED" ;;
    write-tree) cat "$PWD/tree.txt" ;;
esac
exit 0
''')
    (root / "bin/xcrun").write_text(r'''#!/bin/sh
[ "$CASE" = coverage-fail ] && exit 27
[ "$CASE" = empty-coverage ] && exit 0
if [ "$CASE" = low-coverage ]; then missed=99; else missed=5; fi
# 쓰기 그룹(정규식 이름 5종·Usb/Write/·쓰기 관문 포트 정의와 실제 구현·USB 쓰기 어댑터, 모두 66개). 파일을 다른 타깃·폴더로 옮기거나 지운 보고는
# 정규식에서 조용히 빠지면 안 되고, 허용한 하위 폴더(Write/)로 옮긴 보고는 통과한다.
writer=RekordboxKit/RekordboxWriter.swift usb=RekordboxKit/Usb/Write/UsbWriter.swift
grid=RekordboxKit/RekordboxGridWriter.swift gate=DJCAdapters/Reflection/RekordboxWriteGate+Live.swift usbdir=RekordboxKit/Usb/Write
port=DJCApplication/Reflection/RekordboxWriteGate.swift usbgate=DJCAdapters/Usb/UsbLibraryEngine+Writer.swift
fillers=56
[ "$CASE" = write-subfolder ] && writer=RekordboxKit/Write/RekordboxWriter.swift
[ "$CASE" = missing-write-file ] && usb=DJCApplication/Usb/UsbWriter.swift
[ "$CASE" = missing-write-name ] && grid=RekordboxKit/Grid/RekordboxGridWriter.swift
[ "$CASE" = missing-write-gate ] && gate=DJCAdapters/Write/RekordboxWriteGate+Live.swift
[ "$CASE" = few-write-files ] && fillers=54
if [ "$CASE" = missing-usb-write ]; then usb=RekordboxKit/Usb/UsbWriter.swift usbdir=RekordboxKit/Usb/Writing; fi
for file in "$writer" RekordboxKit/RekordboxWriter+Cues.swift RekordboxKit/RekordboxTrackWriter.swift "$grid" \
            RekordboxKit/RekordboxCompatibility.swift RekordboxKit/RekordboxTrackAdd.swift "$usb" "$port" "$gate" "$usbgate"; do
    printf '%s 0 0 0 0 0 0 100 %s 95%%\n' "$file" "$missed"
done
i=1
while [ $i -le $fillers ]; do
    printf '%s/Usb%02d.swift 0 0 0 0 0 0 100 %s 95%%\n' "$usbdir" $i "$missed"
    i=$((i + 1))
done
printf 'DJCDomain/Cue.swift 0 0 0 0 0 0 100 %s 95%%\n' "$missed"
''')
    (root / "bin/tee").write_text('''#!/bin/sh
# 모듈 경계·문서·훅·시험 지도 단계는 지나 보내고 빌드 단계의 파이프에서 실패한다.
case "$1" in *imports.log|*docs.log|*prose.log|*harness.log|*test-map.log) ;; *) [ "$CASE" = pipe-fail ] && exit 28 ;; esac
exec /usr/bin/tee "$@"
''')
    (root / "bin/sleep").write_text('''#!/bin/sh
if [ "$CASE" = split-output ] && [ "$1" = 60 ]; then
    exec /bin/sleep 0.1
fi
exec /bin/sleep "$@"
''')
    (root / "bin/pgrep").write_text('''#!/bin/sh
# pulse-orphan: 자식 찾기(-P)가 자식을 못 보는 경쟁을 흉내 낸다.
if [ "$1" = -P ] && [ "$CASE" = pulse-orphan ]; then exit 1; fi
if [ "$1" = -f ]; then
    case "$CASE" in app-running-write|preferences-leak-app-running) echo 4242; exit 0 ;; esac
    exit 1
fi
exec /usr/bin/pgrep "$@"
''')
    # 합성 HOME: 실제 사용자 폴더를 보지도 쓰지도 않고, 이미 있는 사용자 파일은 그대로 두는 경우를 함께 본다.
    existing = root / "home/Library/Application Support/DJCrate/cue-drafts/existing.json"
    existing.parent.mkdir(parents=True)
    existing.write_text("{}")
    # 이전 실행·다른 작업자가 남긴 시험 설정 파일은 이번 실행의 실패로 세지 않는다.
    old_leak = root / "home/Library/Preferences/djc-test-0A1B2C3D-0000-0000-0000-000000000000.plist"
    old_leak.parent.mkdir(parents=True)
    old_leak.write_text("<plist/>")
    # 합성 "실제 rekordbox 라이브러리": 검사 전후 지문을 비교하는 대상(바뀌면 종료 코드 3).
    live = root / "home/Library/Pioneer/rekordbox/master.db"
    live.parent.mkdir(parents=True)
    live.write_text("라이브 DB")
    for executable in (root / "bin").iterdir():
        executable.chmod(0o755)


def check_case(case, expected):
    with tempfile.TemporaryDirectory(prefix="djc-check-contract-") as directory:
        root = Path(directory)
        prepare(root)
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE=case, HOME=str(root / "home"),
                   LEAKS=json.dumps(LEAKS), PREFERENCE_LEAKS=json.dumps(PREFERENCE_LEAKS))
        for name in ("DJC_TEST_DEFAULTS_PREFIX", "DJC_CHECK_LOG_ROOT", "DJC_CIPHER_STRESS", "DJC_CHECK_VERBOSE",
                     "DJC_HOME", "DJC_REKORDBOX_DIR"):
            env.pop(name, None)
        if case in VERBOSE_CASES:
            env["DJC_CHECK_VERBOSE"] = "1"
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
            if case not in {"pipe-fail", "empty-output", "partial-output", "docs-fail", "prose-fail", "harness-fail"} and "합성 출력" not in (run / "debug-build.log").read_text():
                errors.append("원래 명령 출력 누락")
            if case in CANCELLATIONS and "취소 전 출력" not in (run / "debug-build.log").read_text():
                errors.append("취소 전 로그 유실")
            if case == "empty-output" and (run / "debug-build.log").read_bytes() != b"":
                errors.append("빈 원문 출력이 바뀜")
            if case == "partial-output":
                original = "stdout\nstderr\n개행 없는 마지막"
                if (run / "debug-build.log").read_text() != original or original not in content:
                    errors.append("stdout/stderr 순서나 개행 없는 마지막 출력 유실")
        if case in LEAKS:
            changed = (runs[0] / "user-folders.diff").read_text() if len(runs) == 1 else ""
            if Path(LEAKS[case]).name not in changed:
                errors.append("바뀐 사용자 파일 목록 누락")
            marker = "⚠" if case == "app-running-write" else "✘ 검사 중 DJCrate 사용자 폴더"
            if marker not in content:
                errors.append("사용자 폴더 변경 알림 누락")
        elif "사용자 폴더·로그 폴더가 바뀌었습니다" in content:
            errors.append("바뀌지 않은 사용자 폴더를 바뀌었다고 알림")
        # 문서·훅 검사가 실패하면 swift를 부르기 전에 끝난다.
        prefix_file = root / "defaults-prefix.txt"
        prefixes = prefix_file.read_text().splitlines() if prefix_file.exists() else []
        if case in {"docs-fail", "prose-fail", "harness-fail"}:
            prefixes = ["djc-test-AAAAAA-"]
        if not prefixes or len(set(prefixes)) != 1 or not re.fullmatch(r"djc-test-[A-Za-z0-9]{6}-", prefixes[0]):
            errors.append(f"시험 설정 접두사를 실행별로 주지 않음: {prefixes}")
        leaked = case in PREFERENCE_LEAKS and case != "preferences-other-run"
        if leaked:
            listed = (runs[0] / "preferences.diff").read_text() if len(runs) == 1 and (runs[0] / "preferences.diff").exists() else ""
            if "deck.leak.plist" not in listed or "✘ 검사 중 사용자 환경설정 폴더" not in content:
                errors.append("이번 실행이 남긴 시험 설정 파일을 알리지 않음")
        elif "사용자 환경설정 폴더" in content:
            errors.append("이번 실행 것이 아닌 시험 설정 파일을 실패로 셈")
        if case not in CANCELLATIONS and "모듈 경계 규칙: 위반 0개" not in content:
            errors.append("모듈 경계 규칙 검사를 먼저 돌리지 않음")
        if case == "missing-write-file" and "쓰기 그룹에 UsbWriter.swift가 없습니다" not in content:
            errors.append("옮긴 쓰기 입구 파일을 알리지 않음")
        if case in {"ok", "write-subfolder"} and not any("쓰기" in line and "(파일 66개," in line for line in content.splitlines()):
            errors.append("쓰기 그룹 파일 수 누락")
        expected_notes = {
            "missing-write-name": "쓰기 그룹에 RekordboxGridWriter 파일이 없습니다",
            "missing-write-gate": "쓰기 그룹에 RekordboxWriteGate+Live.swift가 없습니다",
            "missing-usb-write": "쓰기 그룹에 Usb/Write/ 파일이 없습니다",
            "few-write-files": "쓰기 그룹 파일이 64개로",
        }
        if case in expected_notes and expected_notes[case] not in content:
            errors.append("쓰기 그룹에서 빠진 파일을 알리지 않음: " + expected_notes[case])
        if case == "split-output" and ("☃" not in content or "▸ 진행:" not in content):
            errors.append("나뉜 UTF-8 출력이나 진행 알림 유실")
        if case == "live-library-write" and "실제 rekordbox 라이브러리 파일이 바뀌었습니다" not in content:
            errors.append("실제 rekordbox 파일 변경을 알리지 않음")
        if case == "stale-profile" and "커버리지 프로파일" not in content:
            errors.append("이번 시험이 만들지 않은 커버리지 프로파일을 읽음")
        # 앱이 켜져 있어 사용자 폴더 변경을 경고로만 넘긴 실행은 통과로 기록하지 않는다(P2-6).
        if case == "app-running-write" and (root / ".build/check-logs/last-pass").exists():
            errors.append("앱이 켜져 사용자 폴더 변경을 가릴 수 없는 실행을 통과로 기록함")
        # 끝 요약 블록: 모든 경우(취소 포함)에 단계·종료 코드·로그 폴더를 몇 줄로 낸다.
        summary = content.split("── 검사 요약", 1)[1] if "── 검사 요약" in content else ""
        if not summary:
            errors.append("끝 요약 블록 누락")
        elif len(runs) == 1 and str(runs[0]) not in summary and runs[0].name not in summary:
            errors.append("요약에 로그 폴더 누락")
        if case == "test-fail" and summary and ("✘" not in summary or "error: 합성 테스트 실패" not in summary
                                                or "실패한_시험" not in summary or "통과한_시험" in summary):
            errors.append("실패 요약에 실패한 시험·첫 오류 줄이 없음:\n" + summary)
        if case == "ok" and summary and ("✔ 통과" not in summary or len(summary.strip().splitlines()) > 13):
            errors.append("통과 요약이 짧지 않음:\n" + summary)
        if case not in VERBOSE_CASES and "✔ Test synthetic() passed" in content:
            errors.append("시험 통과 줄을 화면에 쏟음")
        if case == "ok" and "✔ Test run with 1 test passed" not in content:
            errors.append("시험 실행 요약 줄(CI가 grep함)을 화면에서 뺌")
        if case == "ansi-fail":
            if "\x1b" in summary or "error: missing import of 'DJCStorage'" not in summary or "MemberImportVisibility" not in summary:
                errors.append("요약의 오류 줄에 터미널 시퀀스가 남거나 오류 글이 빠짐:\n" + repr(summary))
            if len(runs) == 1 and "\x1b[1;31merror:" not in (runs[0] / "debug-build.log").read_text():
                errors.append("로그 원문의 색 코드를 지움")
        light = (root / "light-calls.txt").read_text().splitlines() if (root / "light-calls.txt").exists() else []
        expected_light = {"docs-fail": ["check-docs.py"], "prose-fail": ["check-docs.py", "check-prose.py"]}.get(
            case, ["check-docs.py", "check-prose.py", "test-harness.py --quiet"])
        if case not in CANCELLATIONS and light[:3] != expected_light:
            errors.append(f"전체 검사가 문서·훅 검사를 돌지 않음: {light}")
        if case in {"docs-fail", "prose-fail", "harness-fail"}:
            stage = {"docs-fail": "문서 검사", "prose-fail": "문장 규칙"}.get(case, "훅 검사")
            if (root / "calls.txt").exists():
                errors.append("문서·훅 검사가 실패했는데 빌드함")
            if f"✘ {stage}" not in summary:
                errors.append(f"요약에 실패한 {stage} 단계가 없음:\n" + summary)
            assert not errors, ", ".join(errors) + "\n" + content
            return
        if case == "ok":
            for stage in ("✔ 문서 검사", "✔ 문장 규칙", "✔ 훅 검사", "✔ 시험 지도 검사"):
                if stage not in summary:
                    errors.append(f"요약에 {stage} 단계가 없음:\n" + summary)
        calls = (root / "calls.txt").read_text().splitlines()
        if case == "debug-fail" and len(calls) != 1:
            errors.append("실패 뒤에도 다음 명령 실행")
        if case == "ok" and (
            calls.count("build --build-tests --enable-code-coverage") != 1
            or "test --skip-build --enable-code-coverage" not in calls
        ):
            errors.append("디버그·테스트 빌드 공유 누락")
        assert not errors, ", ".join(errors) + "\n" + content


def check_partition(arguments, case, expected, expected_calls):
    with tempfile.TemporaryDirectory(prefix="djc-check-partition-") as directory:
        root = Path(directory)
        prepare(root)
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE=case, HOME=str(root / "home"),
                   LEAKS=json.dumps(LEAKS), PREFERENCE_LEAKS=json.dumps(PREFERENCE_LEAKS))
        env.pop("DJC_TEST_DEFAULTS_PREFIX", None)
        env.pop("DJC_CHECK_LOG_ROOT", None)
        env.pop("DJC_CIPHER_STRESS", None)
        if case.startswith("stress-env-"):
            env["DJC_CIPHER_STRESS"] = {"stress-env-invalid": "true", "stress-env-empty": "", "stress-env-zero": "0"}[case]
        result = subprocess.run(
            ["/bin/zsh", str(root / "scripts/check.sh"), *arguments], cwd=root, env=env,
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == expected, f"종료코드 {result.returncode}, 기대값 {expected}\n{result.stdout}"
        calls_file = root / "calls.txt"
        calls = calls_file.read_text().splitlines() if calls_file.exists() else []
        assert calls == expected_calls, f"검사 범위 불일치: {calls}"
        light_file = root / "light-calls.txt"
        light = light_file.read_text().splitlines() if light_file.exists() else []
        if arguments == ["--coverage"]:
            assert light == ["check-docs.py", "check-prose.py", "test-harness.py --quiet"], f"--coverage(CI)가 문서·훅 검사를 돌지 않음: {light}"
        else:
            assert not light, f"{arguments}가 문서·훅 검사를 돎(CI의 coverage 묶음이 돈다): {light}"
        if expected_calls:
            run, = (root / ".build/check-logs").glob("run.*")
            assert (run / "exit-code.txt").read_text().strip() == str(expected), "종료코드 보존 누락"
            if arguments == ["--coverage"] and expected == 0:
                assert "목표 80%" in result.stdout and "목표 60%" in result.stdout, "커버리지 목표 검사 누락"
            if arguments and arguments[0] in {"--quick", "--stress"}:
                mode = arguments[0][2:]
                info = (run / "run-info.txt").read_text()
                test_filter = arguments[2] if mode == "quick" else "CipherColdOpenTests"
                for field in (f"mode={mode}", f"filter={test_filter}", "debug=coverage", "release=off",
                              "head=synthetic-head", "dirty=" + ("yes" if case == "dirty" else "no")):
                    assert field in info and field in result.stdout, f"검사 메타데이터 누락: {field}"
                assert not (run / "coverage.log").exists(), "부분 검사에서 커버리지 목표를 검사함"
                if expected == 0:
                    assert f"통과: {mode}" in result.stdout, "부분 성공의 모드 누락"
                    assert "목표 80%" not in result.stdout, "부분 검사를 전체 커버리지로 보고함"
                if mode == "stress":
                    values = (root / "stress-env.txt").read_text().splitlines()
                    assert values == ["1"] * len(expected_calls), f"stress 모드의 환경값 불일치: {values}"
                elif case == "stress-env-zero":
                    assert (root / "stress-env.txt").read_text().splitlines() == ["0", "0"], "일반 모드 환경값을 덮어씀"
            if case == "repeat":
                again = subprocess.run(
                    ["/bin/zsh", str(root / "scripts/check.sh"), *arguments], cwd=root, env=env,
                    capture_output=True, text=True, timeout=10,
                )
                assert again.returncode == 0, "반복 실행 실패"
                if arguments[0] == "--stress":
                    # stress는 확률 시험이라 같은 코드여도 늘 다시 돌린다.
                    assert calls_file.read_text().splitlines() == expected_calls * 2, "stress를 재사용함"
                    assert len(list((root / ".build/check-logs").glob("run.*"))) == 2, "반복 로그를 덮어씀"
                    prefixes = set((root / "defaults-prefix.txt").read_text().splitlines())
                    assert len(prefixes) == 2, f"시험 설정 접두사가 실행마다 다르지 않음: {prefixes}"
                else:
                    # 같은 작업 트리·모드·필터의 통과 기록이 있으면 돌리지 않고 그 로그 폴더를 알린다.
                    assert calls_file.read_text().splitlines() == expected_calls, "같은 작업 트리인데 다시 돌림"
                    assert f"재사용: {run.resolve()}" in again.stdout or f"재사용: {run}" in again.stdout, \
                        "재사용한 로그 폴더를 알리지 않음\n" + again.stdout
                    assert len(list((root / ".build/check-logs").glob("run.*"))) == 1, "재사용인데 로그 폴더를 만듦"


# 모듈 경계 규칙(scripts/check-imports.py): 합성 소스 트리·빚 목록 → (종료코드, 출력에 있어야 할 줄, 빌드까지 갔는지)
DEBT_LINE = "Sources/DJCApplication/Reader.swift\timport\tRekordboxKit\n"
# 뷰 규칙 경우의 합성 뷰 머리
VIEW_HEAD = "import SwiftUI\nstruct LibraryView: View {\n    var body: some View {\n        "
IMPORT_CASES = {
    "imports-clean": ({"Sources/DJCApplication/Ok.swift": "import DJCDomain\nimport Foundation\n"}, "", 0, "위반 0개", True),
    "imports-new-violation": ({"Sources/DJCApplication/Reader.swift": "import RekordboxKit\n"}, "", 1,
                              "✘ 새 위반: Sources/DJCApplication/Reader.swift\timport\tRekordboxKit", False),
    "imports-in-debt": ({"Sources/DJCApplication/Reader.swift": "@testable import RekordboxKit\n"}, DEBT_LINE, 0, "빚 1개", True),
    "imports-paid-debt": ({"Sources/DJCApplication/Reader.swift": "import DJCDomain\n"}, DEBT_LINE, 1,
                          "✘ 갚은 빚(빚 목록에서 지워도 됨): Sources/DJCApplication/Reader.swift", False),
    "imports-infra-up": ({"Sources/RekordboxKit/Up.swift": "import DJCApplication\n"}, "", 1, "Up.swift\timport\tDJCApplication", False),
    "imports-core-api": ({"Sources/DJCDomain/Clock.swift": "let now = Date()\nlet id = UUID()\n"}, "", 1,
                         "Clock.swift\tapi\tDate()", False),
    "imports-api-in-comment": ({"Sources/DJCDomain/Clock.swift":
                                '// FileManager로 읽지 않는다. Date()\n/* UUID() /* 중첩 */ ProcessInfo */\nlet s = "Bundle.main \\(1) UserDefaults"\n'
                                'let t = #"Date()"#\nlet u = """\nUUID()\n"""\n'}, "", 0, "위반 0개", True),
    "imports-app-view": ({"Sources/DJCrate/Library/LibraryView.swift": "import DJCStorage\nimport SwiftUI\n"}, "", 1,
                         "LibraryView.swift\timport\tDJCStorage", False),
    "imports-app-assembly": ({"Sources/DJCrate/App/AppComposition.swift": "import DJCStorage\nimport DJCAdapters\n",
                              "Sources/DJCrate/Diagnostics/SelfTest.swift": "import RekordboxKit\n",
                              "Sources/djc/Lab/LabSQL.swift": "import RekordboxKit\n"}, "", 0, "위반 0개", True),
    "imports-cli-command": ({"Sources/djc/Commands/ReadCommands.swift": "import RekordboxKit\n"}, "", 1,
                            "ReadCommands.swift\timport\tRekordboxKit", False),
    "imports-unknown-module": ({"Sources/NewModule/New.swift": "import Foundation\n"}, "", 1, "규칙이 없는 모듈입니다: NewModule", False),
    "imports-test-defaults": ({"Tests/DJCrateTests/LeakTests.swift": 'let d = UserDefaults(suiteName: "x")!\n'}, "", 1,
                              "LeakTests.swift\ttest-defaults", False),
    "imports-bad-debt-line": ({}, "파일만 있는 줄\n", 1, "빚 목록 줄 모양이 틀렸습니다", False),
    # 어느 타깃에도 속하지 않는 Swift 파일(재료 폴더를 옮기고 Package.swift만 고침)은 검사에서 빠지지 않고 실패한다.
    "imports-no-target": ({"Tests/Support/Moved/Fake.swift": "import RekordboxKit\n"}, "", 1,
                          "어느 타깃에도 속하지 않는 Swift 파일입니다: Tests/Support/Moved/Fake.swift", False),
    # 타깃 경로는 Package.swift에서 읽는다: 재료 타깃을 다른 폴더(시험 타깃 폴더 안 포함)로 옮겨도 그 타깃의 규칙으로 본다.
    "imports-package-path": ({"Tests/Support/Kit/Ports/Fake.swift": "import DJCApplication\nimport DJCTestKit\n"}, "", 0,
                             "위반 0개", True),
    "imports-unlisted-target": ({"Tests/DJCDomainTests/Kit/Helper.swift": "import Foundation\n"}, "", 1,
                                "규칙이 없는 모듈입니다: DomainKit", False),
    # 조립 지점 예외는 파일 이름으로만 준다: 이름이 비슷한 새 파일(접두 패턴이면 통과하던 것)은 화면 쪽 규칙을 따른다.
    "imports-assembly-prefix": ({"Sources/DJCrate/App/AppCompositionHelpers.swift": "import DJCStorage\n"}, "", 1,
                                "AppCompositionHelpers.swift\timport\tDJCStorage", False),
    # CLI 명령 표(CLI.swift)는 더 예외가 아니다(compat 본문은 명령 파일·유스케이스·조립 지점으로 옮겼다).
    "imports-cli-entry": ({"Sources/djc/CLI.swift": "import RekordboxKit\n"}, "", 1, "CLI.swift\timport\tRekordboxKit", False),
    # 목록에 적은 예외 파일이 없으면(지웠거나 옮김) 목록을 고치게 한다.
    "imports-stale-assembly": ({"Sources/djc/CLIComposition+Usb.swift": None}, "", 1,
                               "예외 목록의 파일이 없습니다: Sources/djc/CLIComposition+Usb.swift", False),
    # 넓은 예외 폴더도 허용 import는 적은 것만: 목록 밖 모듈은 위반이고, 적었는데 아무도 쓰지 않으면 목록을 줄이게 한다.
    "imports-broad-folder": ({"Sources/djc/Lab/LabCipher.swift": "import SQLCipher\n"}, "", 1,
                             "LabCipher.swift\timport\tSQLCipher", False),
    "imports-broad-unused": ({"Sources/DJCrate/Diagnostics/Placeholder.swift": "import DJCAdapters\nimport DJCStorage\nimport RekordboxKit\n"}, "",
                             1, "예외가 쓰지 않는 모듈을 허용합니다: Sources/DJCrate/Diagnostics/ DJCAnalysis", False),
    # 핵심부 API: 환경 타입 Bundle은 이름 자체를, .main·.current·.now는 타입을 쓰지 않은 암묵 멤버도 잡는다(UIStrings의 Mutex<Bundle>(.main)).
    "imports-core-bundle": ({"Sources/DJCDomain/Strings.swift": "let storage = Mutex<Bundle>(.main)\nlet locale = Mutex<Locale>(.current)\n"}, "", 1,
                            "Strings.swift\tapi\tBundle", False),
    "imports-core-implicit": ({"Sources/DJCApplication/Clock.swift":
                               "func f(locale: Locale = .current) {}\nlet zone = TimeZone.current\nlet t: Date = .now\nlet q = g(queue: .main)\n"
                               "func h() -> Locale { return .current }\n"}, "", 1,
                              "Clock.swift\tapi\t.main·.current·.now(암묵 멤버)", False),
    "imports-core-implicit-names": ({"Sources/DJCApplication/Clock.swift": "let zone = TimeZone.current\n"}, "", 1,
                                    "Clock.swift\tapi\tLocale·TimeZone·Calendar.current", False),
    "imports-core-explicit-ok": ({"Sources/DJCApplication/Ok.swift":
                                  "let a = display.current\nlet b = value?.main\nlet c: Mode = .currentUsb\nlet d = DeckShortcuts.standard\n"
                                  "let e = rows\n    .current\nlet f = Locale(identifier: \"en_US_POSIX\")\n"}, "", 0, "위반 0개", True),
    # 핵심부에는 화면 상태가 없다: 관찰(Observation)은 앱 화면 모델에 둔다.
    "imports-core-observable": ({"Sources/DJCApplication/Session.swift": "import Observation\n@Observable final class Session {}\n"}, "", 1,
                                "Session.swift\tapi\tObservation", False),
    # 뷰 규칙(MVVM): View를 채택한 타입이 든 앱 파일은 Task를 시작하지 않고 await하지 않는다(화면 모델 메서드를 부른다).
    "imports-view-task": ({"Sources/DJCrate/Library/LibraryView.swift":
                           """%sButton("저장") { Task { await model.save() } }\n    }\n}\n""" % VIEW_HEAD}, "", 1,
                          "LibraryView.swift\tview-task\tTask 1곳", False),
    "imports-view-task-detached": ({"Sources/DJCrate/Library/LibraryView.swift":
                                    VIEW_HEAD + 'Text("a").onAppear { Task.detached(priority: .low) { load() } }\n    }\n}\n'}, "", 1,
                                   "LibraryView.swift\tview-task\tTask 1곳", False),
    # 허용: 수명 수식어 .task에서 화면 모델 메서드 하나를 await만 하는 것(SwiftUI가 수명을 맡고, 뷰에는 로직이 없다).
    "imports-view-task-modifier": ({"Sources/DJCrate/Library/LibraryView.swift":
                                    VIEW_HEAD + 'Text("a").task { await model.load(store: store) }\n'
                                    '            .task(id: Request(source: source?.track, revision: revision)) {\n'
                                    '                await model.load(source: source?.track, rows: rows)\n            }\n    }\n'
                                    '    @State private var job: Task<Void, Never>?\n}\n'}, "", 0, "위반 0개", True),
    # 수식어 안이라도 로직·호출 둘 이상·받는 쪽 없는 호출(뷰 자신의 메서드)은 센다.
    "imports-view-task-modifier-logic": ({"Sources/DJCrate/Library/LibraryView.swift":
                                          VIEW_HEAD + 'Text("a").task { if await model.load() { dismiss() } }\n'
                                          '            .task { await load() }\n            .task { await app.runner().loop() }\n    }\n}\n'},
                                         "", 1, "LibraryView.swift\tview-task\tawait 3곳", False),
    # 뷰가 아닌 앱 파일(화면 모델)·AppKit 다리(NSViewRepresentable)는 보지 않는다.
    "imports-view-task-not-view": ({"Sources/DJCrate/Library/LibraryModel.swift":
                                    "final class LibraryModel {\n    func save() { Task { await store.save() } }\n}\n",
                                    "Sources/DJCrate/Library/TableBridge.swift":
                                    "struct TableBridge: NSViewRepresentable {\n    func update() { Task { await x.y() } }\n}\n"}, "", 0, "위반 0개", True),
    # 지금 있는 것은 빚 목록에 곳 수로 고정한다. 같으면 통과, 늘면 새 위반, 줄면 빚 목록을 고치게 한다.
    "imports-view-task-in-debt": ({"Sources/DJCrate/Library/LibraryView.swift":
                                   VIEW_HEAD + 'Button("a") { Task { save() } }\n        Button("b") { Task { save() } }\n    }\n}\n'},
                                  "Sources/DJCrate/Library/LibraryView.swift\tview-task\tTask 2곳\n", 0, "빚 1개", True),
    "imports-view-task-more": ({"Sources/DJCrate/Library/LibraryView.swift":
                                VIEW_HEAD + 'Button("a") { Task { save() } }\n        Button("b") { Task { save() } }\n    }\n}\n'},
                               "Sources/DJCrate/Library/LibraryView.swift\tview-task\tTask 1곳\n", 1,
                               "✘ 새 위반: Sources/DJCrate/Library/LibraryView.swift\tview-task\tTask(빚 1곳 → 지금 2곳)", False),
    "imports-view-task-fewer": ({"Sources/DJCrate/Library/LibraryView.swift":
                                 VIEW_HEAD + 'Button("a") { Task { save() } }\n    }\n}\n'},
                                "Sources/DJCrate/Library/LibraryView.swift\tview-task\tTask 2곳\n", 1,
                                "✘ 갚은 빚(빚 목록 고치기): Sources/DJCrate/Library/LibraryView.swift\tview-task\tTask(빚 2곳 → 지금 1곳)", False),
    # --summary는 빚 표와 함께 예외 목록을 보이고 폴더 예외가 넓다는 사실을 따로 적는다.
    "imports-summary": ({}, "", 0, "위반 0개", True),
}
# 경우마다 합성 패키지에 더하거나 바꿀 타깃(이름, 종류, 경로)
IMPORT_TARGETS = {
    "imports-unknown-module": [("NewModule", "regular", None)],
    "imports-package-path": [("PortTestKit", "regular", "Tests/Support/Kit/Ports")],
    "imports-unlisted-target": [("DomainKit", "regular", "Tests/DJCDomainTests/Kit")],
}


def check_imports(case, files, debt, expected, note, built):
    with tempfile.TemporaryDirectory(prefix="djc-check-imports-") as directory:
        root = Path(directory)
        prepare(root)
        for relative, content in files.items():
            if content is None:
                (root / relative).unlink()
                continue
            (root / relative).parent.mkdir(parents=True, exist_ok=True)
            (root / relative).write_text(content)
        (root / "scripts/import-debt.txt").write_text("# 합성 빚 목록\n" + debt)
        if case in IMPORT_TARGETS:
            changed = {name: (name, kind, path) for name, kind, path in IMPORT_TARGETS[case]}
            targets = [changed.pop(name, (name, kind, path)) for name, kind, path in PREPARE_TARGETS] + list(changed.values())
            (root / "dump.json").write_text(package_dump(targets))
        env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE="ok", HOME=str(root / "home"),
                   LEAKS=json.dumps(LEAKS), PREFERENCE_LEAKS=json.dumps(PREFERENCE_LEAKS))
        for name in ("DJC_TEST_DEFAULTS_PREFIX", "DJC_CHECK_LOG_ROOT", "DJC_CIPHER_STRESS"):
            env.pop(name, None)
        result = subprocess.run(
            ["/bin/zsh", str(root / "scripts/check.sh"), "--quick", "--filter", "SampleTests"], cwd=root, env=env,
            capture_output=True, text=True, timeout=20,
        )
        assert result.returncode == expected, f"종료코드 {result.returncode}, 기대값 {expected}\n{result.stdout}{result.stderr}"
        assert note in result.stdout, f"출력에 {note!r} 없음\n{result.stdout}"
        assert (root / "calls.txt").exists() == built, "모듈 경계 위반에도 빌드함" if not built else "통과했는데 빌드하지 않음"
        if case == "imports-summary":
            summary = subprocess.run([sys.executable, str(root / "scripts/check-imports.py"), "--summary"], cwd=root, env=env,
                                     capture_output=True, text=True, timeout=20)
            assert summary.returncode == 0, summary.stdout + summary.stderr
            for line in ("| Sources/DJCrate/App/AppComposition.swift | 조립 지점(파일) |",
                         "| Sources/djc/Lab/ | 넓은 예외(폴더) |", "| Sources/DJCrate/Diagnostics/ | 넓은 예외(폴더) |",
                         "넓은 예외(폴더 단위, 허용 import 목록은 위 표):"):
                assert line in summary.stdout, f"요약에 {line!r} 없음\n{summary.stdout}"
        if case == "imports-new-violation":
            # 빚 목록 다시 쓰기(--write-debt) 뒤에는 같은 위반이 빚으로 통과한다.
            subprocess.run([sys.executable, str(root / "scripts/check-imports.py"), "--write-debt"], check=True,
                           capture_output=True, timeout=20)
            assert DEBT_LINE in (root / "scripts/import-debt.txt").read_text(), "빚 목록에 위반을 적지 않음"
            again = subprocess.run([sys.executable, str(root / "scripts/check-imports.py")], capture_output=True, text=True, timeout=20)
            assert again.returncode == 0, "다시 쓴 빚 목록으로 통과하지 않음\n" + again.stdout


# 바꾼 파일 → 시험 고르기(scripts/affected-tests.py). 실제 모듈 이름을 쓴 작은 합성 패키지로 본다
# (모듈 경계 검사가 모르는 모듈 이름을 거부하므로). 시험 타깃 4개, Suite 9개.
SYNTHETIC_TARGETS = [
    ("SQLCipher", "binary", None, []),
    ("DJCDomain", "regular", None, []),
    ("DJCApplication", "regular", None, ["DJCDomain"]),
    ("RekordboxKit", "regular", None, ["DJCDomain", "SQLCipher"]),
    ("djc", "regular", None, ["DJCApplication"]),
    ("DJCrate", "regular", None, ["DJCApplication"]),
    ("djcExecutable", "executable", None, ["djc"]),
    ("DJCTestKit", "regular", "Tests/Support/Kit", ["DJCDomain"]),
    ("DJCDomainTests", "test", None, ["DJCDomain", "DJCTestKit"]),
    ("DJCApplicationTests", "test", None, ["DJCApplication", "DJCDomain"]),
    ("RekordboxKitTests", "test", None, ["RekordboxKit", "DJCDomain"]),
    ("djcTests", "test", None, ["djc"]),
]
SYNTHETIC_FILES = {
    "Package.swift": "// 합성 패키지\n",
    ".gitignore": "fakebin/\nswift-calls.txt\ndump.json\n.build/\n",
    "Sources/DJCDomain/Foo.swift": "public struct Foo {\n    public init() {}\n}\n",
    "Sources/DJCDomain/Foo+Format.swift": "extension Foo {\n    var text: String { \"\" }\n}\n",
    "Sources/DJCDomain/Bar.swift": "public enum Bar {}\n",
    "Sources/DJCApplication/AppThing.swift": "import DJCDomain\npublic struct AppThing {}\n",
    "Sources/DJCApplication/Lonely.swift": "struct Lonely {}\n",
    "Sources/DJCApplication/Prompt.swift": "struct Prompt {\n    let title = String(ui: \"안녕\")\n}\n",
    "Sources/RekordboxKit/RekordboxWriter.swift": "public enum RekordboxWriter {}\n",
    "Sources/djc/Command.swift": "struct Command {}\n",
    "Sources/djcExecutable/main.swift": "print(1)\n",
    "Sources/DJCrate/Resources/Localizable.xcstrings": "{}\n",
    "Tests/Support/Kit/Helper.swift": "public struct KitHelper {}\n",
    "Tests/DJCDomainTests/FooTests.swift": "import Testing\nstruct FooTests {\n    @Test func a() { _ = Foo() }\n}\n",
    "Tests/DJCDomainTests/DomainMiscTests.swift": "import Testing\nstruct DomainMiscTests {\n    @Test func a() {}\n}\n",
    "Tests/DJCDomainTests/Domain2Tests.swift": "import Testing\nstruct Domain2Tests {\n    @Test func a() { _ = DomainFixture() }\n}\n",
    "Tests/DJCDomainTests/Domain3Tests.swift": "import Testing\n@Suite(\"셋\") struct Domain3Tests {\n    @Test func a() {}\n}\n",
    "Tests/DJCDomainTests/Helpers.swift": "struct DomainFixture {}\n",
    "Tests/DJCApplicationTests/AppThingTests.swift": "import Testing\nstruct AppThingTests {\n    @Test func a() { _ = (AppThing(), Foo()) }\n}\n",
    "Tests/RekordboxKitTests/WriterTests.swift": "import Testing\nstruct WriterTests {\n    @Test func a() { _ = RekordboxWriter.self }\n}\n",
    "Tests/RekordboxKitTests/WriteGuardTests.swift": "import Testing\nstruct WriteGuardTests {\n    @Test func a() {}\n}\n",
    "Tests/RekordboxKitTests/KitMiscTests.swift": "import Testing\nstruct KitMiscTests {\n    @Test func a() {}\n}\n",
    "Tests/djcTests/CommandTests.swift": "import Testing\nstruct CommandTests {\n    @Test func a() { _ = Command() }\n}\n",
}
SYNTHETIC_MAP = """# 합성 시험 지도
group rekordbox-safety
when Sources/RekordboxKit/RekordboxWriter*.swift
suite RekordboxKitTests.WriteGuardTests
note 쓰기 관문을 바꿨으면 안전 시험이 함께 돕니다
require 합성 필수 검사를 돌리세요
maybe Sources/RekordboxKit/Write/RekordboxWriter*.swift

group write-coverage
when Sources/RekordboxKit/RekordboxWriter*.swift
check write-coverage
target RekordboxKitTests

group djc-process
when Sources/djcExecutable/**
target djcTests

group localization
when Sources/**/*.xcstrings
suite DJCDomainTests.DomainMiscTests

group no-tests
when .gitignore
none

needs djcTests djc
"""


def synthetic_dump():
    targets = []
    for name, kind, path, dependencies in SYNTHETIC_TARGETS:
        target = {"name": name, "type": kind, "dependencies": [{"byName": [d, None]} for d in dependencies]}
        if path:
            target["path"] = path
        targets.append(target)
    return json.dumps({"name": "DJCrate", "targets": targets})


def make_synthetic_repo(root, test_map=SYNTHETIC_MAP):
    """합성 패키지와 package dump-package만 아는 가짜 swift(부를 때마다 swift-calls.txt에 남김)."""
    for relative, content in SYNTHETIC_FILES.items():
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        (root / relative).write_text(content)
    (root / "scripts").mkdir(exist_ok=True)
    shutil.copy(AFFECTED, root / "scripts/affected-tests.py")
    (root / "scripts/test-map.txt").write_text(test_map)
    (root / "dump.json").write_text(synthetic_dump())
    fake = root / "fakebin"
    fake.mkdir(exist_ok=True)
    (fake / "swift").write_text(f"#!{sys.executable}\n" + r'''
import pathlib, sys
root = pathlib.Path.cwd()
with open(root / "swift-calls.txt", "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["package", "dump-package"]:
    print((root / "dump.json").read_text())
    sys.exit(0)
sys.exit(9)
''')
    (fake / "swift").chmod(0o755)


def run_affected(root, *arguments):
    env = dict(os.environ, PATH=str(root / "fakebin") + ":" + os.environ["PATH"])
    return subprocess.run([sys.executable, str(root / "scripts/affected-tests.py"), *arguments], cwd=root, env=env,
                          capture_output=True, text=True, timeout=30)


def affected_json(root, *files):
    result = run_affected(root, "--files", *files, "--json")
    assert result.returncode == 0, f"종료코드 {result.returncode}\n{result.stdout}{result.stderr}"
    return json.loads(result.stdout)


# 바꾼 파일 → (범위, 고른 Suite, 통째로 고른 타깃, 빌드할 타깃, 켤 검사, 이유에 있어야 할 말)
AFFECTED_CASES = {
    "affected-test-file": (["Tests/DJCDomainTests/FooTests.swift"], "tests",
                           ["DJCDomainTests.FooTests"], [], ["DJCDomainTests"], ["imports"], "시험 파일"),
    "affected-source-direct-and-symbol": (["Sources/DJCDomain/Foo.swift"], "tests",
                                          ["DJCApplicationTests.AppThingTests", "DJCDomainTests.FooTests"], [],
                                          ["DJCApplicationTests", "DJCDomainTests"], ["imports"], "Foo"),
    "affected-extension-file": (["Sources/DJCDomain/Foo+Format.swift"], "tests",
                                ["DJCApplicationTests.AppThingTests", "DJCDomainTests.FooTests"], [],
                                ["DJCApplicationTests", "DJCDomainTests"], ["imports"], "Foo"),
    "affected-safety-map": (["Sources/RekordboxKit/RekordboxWriter.swift"], "tests",
                            ["RekordboxKitTests.WriteGuardTests", "RekordboxKitTests.WriterTests"], ["RekordboxKitTests"],
                            ["RekordboxKitTests"], ["imports", "write-coverage"], "rekordbox-safety"),
    "affected-untested-source": (["Sources/DJCApplication/Lonely.swift"], "tests",
                                 [], ["DJCApplicationTests", "djcTests"], ["DJCApplicationTests", "djcTests"], ["imports"],
                                 "시험이 닿지 않는 소스"),
    "affected-test-helper": (["Tests/DJCDomainTests/Helpers.swift"], "tests",
                             [], ["DJCDomainTests"], ["DJCDomainTests"], ["imports"], "시험 도우미"),
    "affected-test-kit": (["Tests/Support/Kit/Helper.swift"], "tests",
                          [], ["DJCDomainTests"], ["DJCDomainTests"], ["imports"], "DJCTestKit"),
    "affected-executable-map": (["Sources/djcExecutable/main.swift"], "tests",
                                [], ["djcTests"], ["djcTests"], ["imports"], "djc-process"),
    "affected-package-widens": (["Package.swift"], "full", [], [], [], [], "Package.swift"),
    "affected-check-script-widens": (["scripts/check.sh"], "full", [], [], [], [], "scripts/check.sh"),
    "affected-github-widens": ([".github/workflows/check.yml"], "full", [], [], [], [], ".github"),
    "affected-half-widens": (["Sources/DJCDomain/Bar.swift"], "full", [], [], [], [], "절반"),
    "affected-unknown-widens": (["weird/thing.bin"], "full", [], [], [], [], "weird/thing.bin"),
    "affected-docs-only": (["docs/ci.md", "AGENTS.md", ".claude/rules/x.md"], "none", [], [], [], [], "문서"),
    "affected-docs-with-checker": (["docs/ci.md"], "none", [], [], [], ["docs"], "check-docs.py"),
    "affected-harness": (["scripts/hooks/guard.sh", ".claude/settings.json"], "none", [], [], [], ["harness"], "test-harness.py"),
    # 하네스 자신(훅·검사 스크립트·.claude)만 바꾸면 넓히지 않고 두 검사만 돈다
    "affected-harness-self": (["scripts/test-harness.py", "scripts/check-docs.py", "scripts/hooks/stop.py",
                               "scripts/check-prose.py", "scripts/prose-baseline.txt", "scripts/prose-terms.txt",
                               "scripts/worker-lock.sh", ".claude/rules/x.md", ".claude/settings.json", ".claude/skills/v/SKILL.md"], "none",
                              [], [], [], ["docs", "harness"], "test-harness.py"),
    "affected-map-none": ([".gitignore"], "none", [], [], [], [], "no-tests"),
    "affected-translations": (["Sources/DJCrate/Resources/Localizable.xcstrings"], "tests",
                              ["DJCDomainTests.DomainMiscTests"], [], ["DJCDomainTests"], ["translations"], "localization"),
    "affected-ui-string": (["Sources/DJCApplication/Prompt.swift"], "tests",
                           [], ["DJCApplicationTests", "djcTests"], ["DJCApplicationTests", "djcTests"], ["imports", "translations"],
                           "화면 문구"),
    "affected-script-tests": (["scripts/affected-tests.py", "scripts/test-map.txt"], "none", [], [], [], ["scripts"],
                              "test-check.py"),
    "affected-imports-only": (["scripts/import-debt.txt"], "none", [], [], [], ["imports"], "모듈 경계"),
    "affected-deleted-test": (["Tests/DJCDomainTests/GoneTests.swift"], "build", [], [], [], ["imports"], "지운"),
}


def check_affected(case, files, scope, suites, whole, targets, checks, reason):
    with tempfile.TemporaryDirectory(prefix="djc-affected-") as directory:
        root = Path(directory)
        make_synthetic_repo(root)
        if case == "affected-docs-with-checker":
            (root / "scripts/check-docs.py").write_text("print('문서 검사')\n")
        if case in ("affected-harness", "affected-harness-self"):
            (root / "scripts/test-harness.py").write_text("print('훅 검사')\n")
        if case == "affected-harness-self":
            (root / "scripts/check-docs.py").write_text("print('문서 검사')\n")
        plan = affected_json(root, *files)
        assert plan["files"] == sorted(files), f"바꾼 파일 목록 불일치: {plan['files']}"
        assert plan["scope"] == scope, f"범위 {plan['scope']}, 기대값 {scope}\n{json.dumps(plan, ensure_ascii=False, indent=1)}"
        if scope == "tests":
            assert sorted(plan["suites"]) == sorted(suites), f"고른 Suite 불일치: {plan['suites']}"
            assert sorted(plan["wholeTargets"]) == sorted(whole), f"통째로 고른 타깃 불일치: {plan['wholeTargets']}"
            assert sorted(plan["targets"]) == sorted(targets), f"빌드할 타깃 불일치: {plan['targets']}"
            # 고른 Suite는 타깃 이름으로 앵커한 정규식 하나로 모은다(앵커가 없으면 다른 타깃의 같은 이름도 맞는다).
            pattern = re.compile(plan["filter"])
            assert plan["filter"].startswith("^"), f"필터가 앵커되지 않음: {plan['filter']}"
            for suite in suites:
                assert pattern.search(suite + "/a()"), f"필터가 {suite}를 고르지 않음: {plan['filter']}"
            for target in whole:
                assert pattern.search(target + ".AnySuite/a()"), f"필터가 {target} 전체를 고르지 않음: {plan['filter']}"
            assert not pattern.search("DJCDomainTests.KitMiscTests/a()") or "DJCDomainTests" in whole, "다른 Suite까지 고름"
            assert not pattern.search("OtherTests.FooTests/a()"), "다른 타깃의 같은 이름 Suite까지 고름"
            if "djcTests" in targets:
                assert plan["products"] == ["djc"], f"djc 프로세스 시험인데 djc 제품을 빌드하지 않음: {plan['products']}"
            else:
                assert plan["products"] == [], f"필요 없는 제품 빌드: {plan['products']}"
        else:
            assert plan["filter"] is None and plan["targets"] == [], "시험을 고르지 않는 범위에 필터가 있음"
        if scope == "full":
            assert plan["widen"] and reason in plan["widen"], f"넓힌 이유 누락: {plan['widen']}"
        else:
            assert plan["widen"] is None, f"넓히지 않아야 함: {plan['widen']}"
            text = json.dumps(plan["reasons"], ensure_ascii=False) + " ".join(plan["notes"])
            assert reason in text, f"이유에 {reason!r} 없음: {text}"
        enabled = sorted(name for name, on in plan["checks"].items() if on)
        assert scope == "full" or enabled == sorted(checks), f"켠 검사 불일치: {enabled}"
        assert {"selectedSuites", "totalSuites"} <= set(plan["counts"]) and plan["counts"]["totalSuites"] == 9, \
            f"Suite 수 누락: {plan['counts']}"
        if case == "affected-safety-map":
            assert any("안전 시험" in note for note in plan["notes"]), "지도의 안내를 출력하지 않음"
            assert plan.get("required") == ["합성 필수 검사를 돌리세요"], f"지도의 필수 검사 누락: {plan.get('required')}"
        # 사람이 읽는 출력: 기본 형식은 이유와 필터를 몇 줄로 보인다.
        human = run_affected(root, "--files", *files)
        assert human.returncode == 0 and ("범위" in human.stdout), f"사람용 출력 누락\n{human.stdout}{human.stderr}"


def check_affected_extra(case):
    with tempfile.TemporaryDirectory(prefix="djc-affected-") as directory:
        root = Path(directory)
        if case == "affected-map-missing-suite":
            make_synthetic_repo(root, SYNTHETIC_MAP + "\ngroup stale\nwhen Sources/DJCDomain/Foo.swift\nsuite DJCDomainTests.GoneTests\n")
            result = run_affected(root, "--files", "Sources/DJCDomain/Foo.swift", "--json")
            assert result.returncode == 2 and "GoneTests" in result.stderr, f"없는 Suite를 지도에서 거부하지 않음\n{result.stdout}{result.stderr}"
        elif case == "affected-dump-cache":
            # Package.swift가 같으면 dump-package를 다시 부르지 않고, 바뀌면 다시 만든다.
            make_synthetic_repo(root)
            affected_json(root, "Sources/DJCDomain/Foo.swift")
            affected_json(root, "Tests/DJCDomainTests/FooTests.swift")
            calls = (root / "swift-calls.txt").read_text().splitlines()
            assert calls == ["package dump-package"], f"패키지 그래프를 캐시하지 않음: {calls}"
            (root / "Package.swift").write_text("// 바뀐 합성 패키지\n")
            affected_json(root, "Sources/DJCDomain/Foo.swift")
            assert len((root / "swift-calls.txt").read_text().splitlines()) == 2, "Package.swift가 바뀌었는데 캐시를 씀"
        elif case == "affected-git-base":
            # --base에 준 트리 해시와 작업 트리(스테이지·추적 안 된 파일 포함)를 비교한다.
            make_synthetic_repo(root)
            git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run(git + ["init", "-q", "-b", "dev"], cwd=root, check=True)
            (root / ".gitignore").write_text("fakebin/\nswift-calls.txt\ndump.json\n.build/\n")
            subprocess.run(git + ["add", "-A"], cwd=root, check=True)
            subprocess.run(git + ["commit", "-qm", "기준"], cwd=root, check=True)
            tree = subprocess.run(["git", "write-tree"], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
            (root / "Sources/DJCDomain/Foo.swift").write_text("public struct Foo {\n    public init() {}\n    // 바꿈\n}\n")
            subprocess.run(["git", "add", "Sources/DJCDomain/Foo.swift"], cwd=root, check=True)
            (root / "Tests/DJCDomainTests/NewTests.swift").write_text("import Testing\nstruct NewTests {\n    @Test func a() {}\n}\n")
            result = run_affected(root, "--base", tree, "--json")
            assert result.returncode == 0, result.stdout + result.stderr
            plan = json.loads(result.stdout)
            assert plan["base"] == tree, f"준 기준을 그대로 쓰지 않음: {plan['base']}"
            assert plan["files"] == ["Sources/DJCDomain/Foo.swift", "Tests/DJCDomainTests/NewTests.swift"], plan["files"]
            assert "DJCDomainTests.NewTests" in plan["suites"], "추적 안 된 새 시험 파일을 고르지 않음"
            # --base가 없으면 dev와의 merge-base를 쓴다.
            plan = json.loads(run_affected(root, "--json").stdout)
            head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
            assert plan["base"] == head, f"기본 기준이 merge-base가 아님: {plan['base']}"
            # 작업 트리 해시: 내용이 같으면 같고, 추적 안 된 파일이 바뀌면 달라진다(통과 기록 재사용 판정).
            first = run_affected(root, "--worktree-tree").stdout.strip()
            assert re.fullmatch(r"[0-9a-f]{40}", first), f"작업 트리 해시 모양: {first!r}"
            assert run_affected(root, "--worktree-tree").stdout.strip() == first, "같은 작업 트리인데 해시가 다름"
            (root / "Tests/DJCDomainTests/NewTests.swift").write_text("import Testing\nstruct NewTests {}\n")
            assert run_affected(root, "--worktree-tree").stdout.strip() != first, "추적 안 된 파일 변경을 해시에 넣지 않음"
            staged = subprocess.run(["git", "diff", "--cached", "--name-only"], cwd=root, check=True, capture_output=True, text=True).stdout
            assert staged.split() == ["Sources/DJCDomain/Foo.swift"], f"해시 계산이 실제 index를 바꿈: {staged!r}"
            # 작업 트리 해시를 기준으로 주면 바뀐 파일이 없다(추적 안 된 파일도 기준과 내용이 같으면 바뀐 것이 아니다).
            now = run_affected(root, "--worktree-tree").stdout.strip()
            plan = json.loads(run_affected(root, "--base", now, "--json").stdout)
            assert plan["files"] == [] and plan["scope"] == "none", f"기준과 같은 추적 안 된 파일을 바뀌었다고 봄: {plan['files']}"
            (root / "Tests/DJCDomainTests/NewTests.swift").write_text("import Testing\nstruct NewTests {\n    @Test func b() {}\n}\n")
            (root / "scripts/__pycache__").mkdir()
            (root / "scripts/__pycache__/x.cpython-314.pyc").write_bytes(b"\0")
            plan = json.loads(run_affected(root, "--base", now, "--json").stdout)
            assert plan["files"] == ["Tests/DJCDomainTests/NewTests.swift"], f"바뀐 추적 안 된 파일·파이썬 캐시 판정: {plan['files']}"
        elif case == "affected-map-stale-when":
            # 지도의 when이 어느 파일에도 맞지 않으면(오타·파일 이동) 실패한다. maybe 줄은 맞는 파일이 없어도 된다.
            make_synthetic_repo(root, SYNTHETIC_MAP + "\ngroup stale\nwhen Sources/Moved/Away*.swift\nsuite DJCDomainTests.FooTests\n")
            for arguments in (["--check-map"], ["--base", "HEAD", "--json"]):
                result = run_affected(root, *arguments)
                assert result.returncode == 2 and "Sources/Moved/Away*.swift" in result.stderr, \
                    f"{arguments}: 맞는 파일 없는 when을 거부하지 않음\n{result.stdout}{result.stderr}"
            make_synthetic_repo(root)
            result = run_affected(root, "--check-map")
            assert result.returncode == 0, f"maybe 줄을 거부함\n{result.stdout}{result.stderr}"
        elif case == "affected-git-rename":
            # 파일을 다른 모듈로 옮기면 옛 경로와 새 경로를 모두 바뀐 파일로 본다(옛 모듈의 시험도 고른다).
            make_synthetic_repo(root)
            git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run(git + ["init", "-q", "-b", "dev"], cwd=root, check=True)
            subprocess.run(git + ["add", "-A"], cwd=root, check=True)
            subprocess.run(git + ["commit", "-qm", "기준"], cwd=root, check=True)
            subprocess.run(git + ["mv", "Sources/DJCApplication/AppThing.swift", "Sources/djc/AppThing.swift"], cwd=root, check=True)
            plan = json.loads(run_affected(root, "--base", "HEAD", "--json").stdout)
            assert plan["files"] == ["Sources/DJCApplication/AppThing.swift", "Sources/djc/AppThing.swift"], \
                f"이름 바꿈의 옛 경로를 빠뜨림: {plan['files']}"
            assert "DJCApplicationTests.AppThingTests" in plan["suites"], f"옛 모듈의 시험을 고르지 않음: {plan['suites']}"
        elif case == "affected-bad-base":
            make_synthetic_repo(root)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            result = run_affected(root, "--base", "no-such-rev", "--json")
            assert result.returncode == 2 and "no-such-rev" in result.stderr, f"없는 기준을 거부하지 않음\n{result.stderr}"
        elif case == "affected-shell-format":
            # check.sh가 eval로 읽는 형식: plan_ 변수만, 값은 따옴표로 감싼다.
            make_synthetic_repo(root)
            result = run_affected(root, "--files", "Sources/DJCDomain/Foo.swift", "--shell")
            assert result.returncode == 0, result.stderr
            names = [line.split("=", 1)[0] for line in result.stdout.splitlines() if "=" in line and not line.startswith(" ")]
            for name in ("plan_scope", "plan_filter", "plan_targets", "plan_products", "plan_checks", "plan_widen", "plan_text"):
                assert name in names, f"{name} 없음: {names}"
            shown = subprocess.run(["/bin/zsh", "-c", 'eval "$1"; print -r -- "$plan_scope|$plan_targets"', "_", result.stdout],
                                   capture_output=True, text=True, check=True).stdout.strip()
            assert shown == "tests|DJCApplicationTests DJCDomainTests", f"eval 결과: {shown!r}"


AFFECTED_EXTRA = ["affected-map-missing-suite", "affected-dump-cache", "affected-git-base", "affected-bad-base",
                  "affected-shell-format", "affected-map-stale-when", "affected-git-rename"]


def check_real_map():
    """저장소의 test-map.txt가 지금 Tests/에 있는 Suite만 적고, 쓰기 커버리지 묶음이 check.sh 쓰기 정규식과 같은 파일을 고르는지."""
    root = Path(__file__).resolve().parent.parent
    result = subprocess.run([sys.executable, str(AFFECTED), "--check-map"], cwd=root, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, f"지도 검사 실패\n{result.stdout}{result.stderr}"
    # check.sh 커버리지 awk에서 쓰기 그룹 조건(`add("쓰기"` 앞의 `$1 ~ /…/`들)을 읽는다.
    block = SOURCE.read_text().split('add("쓰기"', 1)[0].rsplit("if ($1 ~ /", 1)[1]
    patterns = []
    for chunk in ("$1 ~ /" + block).split("$1 ~ /")[1:]:
        end = next(i for i in range(len(chunk)) if chunk[i] == "/" and chunk[i - 1] != "\\")
        patterns.append(chunk[:end].replace("\\/", "/"))
    assert len(patterns) == 4, f"check.sh 쓰기 정규식을 찾지 못함: {patterns}"
    write_patterns = [re.compile(p) for p in patterns]
    files = sorted(str(p.relative_to(root / "Sources")) for p in (root / "Sources").rglob("*.swift"))
    in_check = {f for f in files if any(p.search(f) for p in write_patterns)}
    listed = subprocess.run([sys.executable, str(AFFECTED), "--list-check", "write-coverage", "--files",
                             *("Sources/" + f for f in files)], cwd=root, capture_output=True, text=True, timeout=120)
    assert listed.returncode == 0, listed.stderr
    in_map = {line[len("Sources/"):] for line in listed.stdout.splitlines() if line}
    assert in_check == in_map, f"쓰기 그룹이 다름: check.sh에만 {sorted(in_check - in_map)}, 지도에만 {sorted(in_map - in_check)}"


# 바꾼 파일 → 반드시 함께 골라야 할 Suite(또는 타깃 전체). 전체 검사로 넓혀져도 된다.
REAL_SAFETY_CASES = {
    # P0-1: djc lab의 임시 폴더 밖 거부(프로세스로 시험해 기호 grep에 걸리지 않는다)
    "safety-usb-scratch": ("Sources/DJCStorage/Usb/UsbScratchPath.swift", [
        "DJCStorageTests.UsbScratchPathTests", "djcTests.UsbSettingLabTests", "djcTests.UsbPlanLabTests",
        "djcTests.UsbExportCommandTests", "djcTests.UsbCommandTests", "djcTests.CLIRefusalTests"]),
    # P0-2: 실물 USB 동의 관문 → CLI·앱의 실물 거부
    "safety-usb-physical": ("Sources/DJCDomain/Usb/UsbPhysicalWriteGate.swift", [
        "DJCDomainTests.UsbPhysicalWriteGateTests", "djcTests.UsbCommandTests", "djcTests.UsbEditCommandTests",
        "DJCrateTests.UsbWriteCoordinatorTests", "DJCrateTests.UsbExportSheetModelTests", "RekordboxKitTests.UsbWriteGuardTests"]),
    "safety-usb-live-db": ("Sources/RekordboxKit/Usb/UsbLiveDatabase.swift", [
        "RekordboxKitTests.UsbWriteGuardTests", "djcTests.UsbCommandTests", "DJCrateTests.UsbWriteCoordinatorTests"]),
    # P0-3: djc 명령은 문자열 명령 이름으로 닿는다 → djcTests 전체
    "safety-djc-command": ("Sources/djc/Commands/MainCommands.swift", ["djcTests"]),
    "safety-djc-lab": ("Sources/djc/Lab/UsbImageLab.swift", ["djcTests", "DJCStorageTests.UsbScratchPathTests"]),
    # P0-4: 쓰기 관문의 보고·백업 값
    "safety-domain-rekordbox": ("Sources/DJCDomain/Rekordbox/RekordboxWriteReport.swift", [
        "RekordboxKitTests.RealLibraryProtectionTests", "RekordboxKitTests.WriteGuardTests",
        "RekordboxKitTests.RekordboxBackupTests", "RekordboxKitTests.RekordboxRestoreChainTests", "DJCrateTests.RestoreTargetTests"]),
    "safety-rekordboxkit": ("Sources/RekordboxKit/PointSnapshot/RekordboxPointSnapshot.swift", [
        "RekordboxKitTests.RealLibraryProtectionTests", "RekordboxKitTests.RekordboxRestoreChainTests"]),
    # P1-3: Suite 없는 시험 도우미 → 그 타깃 전체(복원 세션 시험 포함)
    "safety-test-helper": ("Tests/DJCApplicationTests/ReflectionFakes.swift", ["DJCApplicationTests"]),
    # P1-4: 어댑터의 .live는 CLI가 프로세스로 쓴다
    "safety-adapters-cli": ("Sources/DJCAdapters/Library/DraftStore+Live.swift", ["djcTests"]),
    # P2-8: 쓰기·복원 대상을 정하는 조립 지점
    "safety-composition": ("Sources/DJCrate/App/AppComposition.swift", [
        "DJCrateTests.RestoreTargetTests", "RekordboxKitTests.RealLibraryProtectionTests"]),
    "safety-location": ("Sources/DJCAdapters/Library/LibraryLocation+Resolve.swift", [
        "DJCrateTests.RestoreTargetTests", "RekordboxKitTests.RealLibraryProtectionTests", "djcTests"]),
    # 시험 격리(#182·LiveDraftHome)
    "safety-environment": ("Sources/DJCEnvironment/TestProcess.swift", [
        "DJCrateTests.ArtworkReflectionTests", "DJCrateTests.RecoverySheetTests", "RekordboxKitTests.RealLibraryProtectionTests",
        "DJCAdaptersTests.AdapterTestEnvironmentTests"]),
}


def check_real_safety(case, path, required):
    root = Path(__file__).resolve().parent.parent
    if not (root / path).exists():
        raise AssertionError(f"경우의 파일이 없습니다(옮겼으면 REAL_SAFETY_CASES를 고치세요): {path}")
    result = subprocess.run([sys.executable, str(AFFECTED), "--files", path, "--json"], cwd=root, capture_output=True,
                            text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    if plan["scope"] == "full":
        return
    assert plan["scope"] == "tests", f"범위 {plan['scope']}"
    whole, suites = set(plan["wholeTargets"]), set(plan["suites"])
    missing = [r for r in required if not (r in whole if "." not in r else (r in suites or r.split(".")[0] in whole))]
    assert not missing, f"{path}: 안전 시험을 고르지 않음: {missing}"


def check_env(root, case="ok", **extra):
    env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"], CASE=case, HOME=str(root / "home"),
               LEAKS=json.dumps(LEAKS), PREFERENCE_LEAKS=json.dumps(PREFERENCE_LEAKS), **extra)
    for name in ("DJC_TEST_DEFAULTS_PREFIX", "DJC_CHECK_LOG_ROOT", "DJC_CIPHER_STRESS", "DJC_CHECK_VERBOSE",
                 "DJC_HOME", "DJC_REKORDBOX_DIR", "DJC_LAYOUT_RECOMPUTE_TESTS"):
        if name not in extra:
            env.pop(name, None)
    return env


def run_check(root, env, *arguments):
    return subprocess.run(["/bin/zsh", str(root / "scripts/check.sh"), *arguments], cwd=root, env=env,
                          capture_output=True, text=True, timeout=120)


def swift_calls(root):
    calls = root / "calls.txt"
    return calls.read_text().splitlines() if calls.exists() else []


def check_reuse(case):
    """통과 기록(.build/check-logs/last-pass)과 재사용 판정."""
    with tempfile.TemporaryDirectory(prefix="djc-check-reuse-") as directory:
        root = Path(directory)
        prepare(root)
        quick = ["--quick", "--filter", "SampleTests"]
        env = check_env(root, "fail-once" if case == "reuse-after-failure" else "ok")
        first = run_check(root, env, *quick)
        if case == "reuse-after-failure":
            assert first.returncode == 26, f"첫 실행이 실패하지 않음\n{first.stdout}"
            assert not (root / ".build/check-logs/last-pass").exists(), "실패한 실행을 통과로 기록함"
            again = run_check(root, env, *quick)
            assert again.returncode == 0 and "재사용:" not in again.stdout, "실패 뒤 다시 돌리지 않음\n" + again.stdout
            third = run_check(root, env, *quick)
            assert "재사용:" in third.stdout and len(swift_calls(root)) == 4, "통과 뒤 같은 트리를 재사용하지 않음"
            return
        assert first.returncode == 0, first.stdout + first.stderr
        record = (root / ".build/check-logs/last-pass").read_text()
        run, = (root / ".build/check-logs").glob("run.*")
        if case == "reuse-last-pass-format":
            assert record.endswith("\n") and record.count("\n") == 1, f"한 줄이 아님: {record!r}"
            fields = dict(part.split("=", 1) for part in record.rstrip("\n").split("\t"))
            assert list(fields)[:8] == ["v", "mode", "filter", "head", "tree", "key", "log", "seconds"], list(fields)
            assert fields["v"] == "1" and fields["mode"] == "quick" and fields["filter"] == "SampleTests"
            assert fields["head"] == "synthetic-head" and fields["tree"] == "a" * 40, fields
            assert re.fullmatch(r"[0-9a-f]{64}", fields["key"]), fields["key"]
            assert Path(fields["log"]) == run.resolve(), f"로그 폴더가 다름: {fields['log']}"
            assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", fields["time"]), fields["time"]
            # 범위·기준: 훅이 아무것도 고르지 않은 --changed 통과(scope=none)를 가려 볼 수 있게 한다.
            assert fields.get("scope") == "tests" and fields.get("base") == "none", fields
            history = (root / ".build/check-logs/pass-history").read_text()
            assert history == record, "통과 이력에 같은 줄을 남기지 않음"
            return
        if case == "reuse-no-reuse":
            second = run_check(root, env, *quick, "--no-reuse")
        elif case == "reuse-tree-changed":
            (root / "tree.txt").write_text("b" * 40 + "\n")
            second = run_check(root, env, *quick)
        elif case == "reuse-other-filter":
            second = run_check(root, env, "--quick", "--filter", "OtherTests")
        elif case == "reuse-env-differs":
            second = run_check(root, check_env(root, DJC_LAYOUT_RECOMPUTE_TESTS="1"), *quick)
        elif case == "reuse-tree-unknown":
            (root / ".build/check-logs/last-pass").unlink()
            (root / ".build/check-logs/pass-history").unlink()
            (root / "tree.txt").write_text("")
            run_check(root, env, *quick)
            assert not (root / ".build/check-logs/last-pass").exists(), "작업 트리 해시를 모르는데 통과로 기록함"
            second = run_check(root, env, *quick)
            assert "재사용:" not in second.stdout and len(swift_calls(root)) == 6, "작업 트리 해시를 모르는데 재사용함"
            return
        elif case == "reuse-full-covers":
            # 같은 작업 트리의 전체 검사 통과는 --changed만 대신한다. --quick은 필터가 1개 이상 맞는지 봐야 해서
            # 같은 모드·필터의 통과 기록만 재사용한다(0개 맞는 필터는 늘 실패). stress는 늘 다시 돈다.
            make_synthetic_repo(root)
            full = run_check(root, env, "--no-reuse")
            assert full.returncode == 0, full.stdout
            before = len(swift_calls(root))
            changed = run_check(root, check_env(root, CHANGED="Tests/DJCDomainTests/FooTests.swift"), "--changed")
            assert "재사용:" in changed.stdout and len(swift_calls(root)) == before, "전체 통과를 --changed에 재사용하지 않음\n" + changed.stdout
            zero = run_check(root, check_env(root, "zero-tests"), "--quick", "--filter", "NoSuchTests")
            assert zero.returncode == 1 and "재사용:" not in zero.stdout, "0개 맞는 --quick 필터를 전체 통과로 넘김\n" + zero.stdout
            other = run_check(root, env, "--quick", "--filter", "OtherTests")
            assert other.returncode == 0 and "재사용:" not in other.stdout, "다른 필터의 --quick을 전체 통과로 넘김"
            stress = run_check(root, env, "--stress")
            assert "재사용:" not in stress.stdout and len(swift_calls(root)) > before, "stress를 전체 통과로 건너뜀"
            return
        elif case == "reuse-tree-moved":
            # 검사 중에 작업 트리가 바뀌면(시작·끝 해시가 다르면) 통과로 기록하지 않는다.
            (root / ".build/check-logs/last-pass").unlink()
            (root / ".build/check-logs/pass-history").unlink()
            moved = run_check(root, check_env(root, "tree-moves"), *quick, "--no-reuse")
            assert moved.returncode == 0, moved.stdout
            assert not (root / ".build/check-logs/last-pass").exists(), "검사 중 바뀐 트리를 통과로 기록함"
            assert "작업 트리가 바뀌" in moved.stdout + moved.stderr, "기록하지 않은 이유를 알리지 않음\n" + moved.stdout
            return
        assert second.returncode == 0, second.stdout + second.stderr
        assert "재사용:" not in second.stdout, f"{case}: 다시 돌려야 하는데 재사용함\n{second.stdout}"
        assert len(swift_calls(root)) == 4, f"{case}: 다시 돌리지 않음: {swift_calls(root)}"


REUSE_CASES = ["reuse-no-reuse", "reuse-tree-changed", "reuse-other-filter", "reuse-env-differs", "reuse-after-failure",
               "reuse-tree-unknown", "reuse-full-covers", "reuse-last-pass-format", "reuse-tree-moved"]


SOURCES = "build --enable-code-coverage"


def build_target(target):
    return f"build --target {target} --enable-code-coverage"


# scripts/check.sh --changed: (인자, 바뀐 파일, 가짜 명령 동작, 종료코드, swift 호출, 출력에 있어야 할 말)
CHANGED_CASES = {
    "changed-test-file": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "ok", 0,
                          [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"],
                          ["범위", "DJCDomainTests.FooTests", "통과: changed", "기준: synthetic-base"]),
    "changed-base": (["--changed", "--base", "abc123"], ["Tests/DJCDomainTests/FooTests.swift"], "ok", 0,
                     [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"], ["abc123"]),
    "changed-no-reuse": (["--changed", "--no-reuse", "--base", "abc123"], ["Tests/DJCDomainTests/FooTests.swift"], "ok", 0,
                         [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"], ["abc123"]),
    "changed-docs": (["--changed"], ["docs/ci.md"], "ok", 0, [], ["빌드·시험 없음", "통과: changed"]),
    "changed-docs-checker": (["--changed"], ["docs/ci.md"], "ok", 0, [], ["문서 검사 통과", "check-prose.py 합성 출력"]),
    "changed-docs-checker-fail": (["--changed"], ["docs/ci.md"], "ok", 1, [], ["문서 검사 실패"]),
    "changed-scripts": (["--changed"], ["scripts/test-map.txt"], "ok", 0, [], ["검사 스크립트 회귀: 1개 중 1개 통과"]),
    "changed-widen": (["--changed"], ["Package.swift"], "ok", 0, [DEBUG, RELEASE, TRANSLATIONS, TEST],
                      ["전체 검사로 넓힙니다", "Package.swift", "목표 60%", "통과: full"]),
    "changed-widen-scripts": (["--changed"], ["Package.swift", "scripts/test-map.txt"], "ok", 0, [DEBUG, RELEASE, TRANSLATIONS, TEST],
                              ["전체 검사로 넓힙니다", "검사 스크립트 회귀: 1개 중 1개 통과", "check-docs.py 합성 출력", "통과: full"]),
    "changed-write": (["--changed"], ["Sources/RekordboxKit/RekordboxWriter.swift"], "ok", 0,
                      [SOURCES, build_target("RekordboxKitTests"), TEST + r" --filter ^(RekordboxKitTests\.)"],
                      ["목표 80%", "rekordbox-safety", "쓰기 관문을 바꿨으면", "⚠ 남은 필수 검사: 합성 필수 검사를 돌리세요"]),
    "changed-write-low": (["--changed"], ["Sources/RekordboxKit/RekordboxWriter.swift"], "low-coverage", 1,
                          [SOURCES, build_target("RekordboxKitTests"), TEST + r" --filter ^(RekordboxKitTests\.)"], ["✘ 쓰기"]),
    "changed-translations": (["--changed"], ["Sources/DJCrate/Resources/Localizable.xcstrings"], "ok", 0,
                             [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(DomainMiscTests)/)",
                              TRANSLATIONS], ["번역"]),
    "changed-djc-product": (["--changed"], ["Sources/djcExecutable/main.swift"], "ok", 0,
                            [SOURCES, build_target("djcTests"), TEST + r" --filter ^(djcTests\.)"], ["djc-process"]),
    "changed-build-only": (["--changed"], ["Tests/DJCDomainTests/GoneTests.swift"], "ok", 0, [DEBUG], ["빌드만"]),
    "changed-build-fail": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "debug-fail", 23,
                           [SOURCES], ["합성 출력"]),
    "changed-test-fail": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "test-fail", 26,
                          [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"],
                          ["실패한_시험", "FooTests.swift:3:5", "error: 합성 테스트 실패"]),
    "changed-user-leak": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "user-folder-write", 4,
                          [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"], ["DJC_HOME 밖"]),
    "changed-preferences-leak": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "preferences-leak", 4,
                                 [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"],
                                 ["사용자 환경설정 폴더"]),
    "changed-live-write": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "live-library-write", 3,
                           [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"],
                           ["실제 rekordbox 라이브러리"]),
    "changed-reuse": (["--changed"], ["Tests/DJCDomainTests/FooTests.swift"], "ok", 0,
                      [SOURCES, build_target("DJCDomainTests"), TEST + r" --filter ^(DJCDomainTests\.(FooTests)/)"], ["재사용:"]),
    "changed-filter-rejected": (["--changed", "--filter", "X"], [], "ok", 2, [], []),
    "changed-base-alone": (["--base", "X"], [], "ok", 2, [], []),
    "changed-base-missing": (["--changed", "--base"], [], "ok", 2, [], []),
    "changed-base-option": (["--changed", "--base", "--no-reuse"], [], "ok", 2, [], []),
    "changed-base-empty": (["--changed", "--base", ""], [], "ok", 2, [], []),
    "changed-twice": (["--changed", "--changed"], [], "ok", 2, [], []),
    "changed-quick-base": (["--quick", "--filter", "A", "--base", "X"], [], "ok", 2, [], []),
    "changed-stress": (["--changed", "--stress"], [], "ok", 2, [], []),
}


def check_changed(case, arguments, changed, mode, expected, expected_calls, notes):
    with tempfile.TemporaryDirectory(prefix="djc-check-changed-") as directory:
        root = Path(directory)
        prepare(root)
        make_synthetic_repo(root)
        if case.startswith("changed-docs-checker"):
            code = 1 if case.endswith("fail") else 0
            word = "실패" if code else "통과"
            (root / "scripts/check-docs.py").write_text(f"import sys\nprint('문서 검사 {word}')\nsys.exit({code})\n")
        if case in {"changed-scripts", "changed-widen-scripts"}:
            (root / "scripts/test-check.py").write_text("print('검사 스크립트 회귀: 1개 중 1개 통과')\n")
        env = check_env(root, mode, CHANGED="\n".join(changed))
        result = run_check(root, env, *arguments)
        if case == "changed-reuse":
            result = run_check(root, env, *arguments)
        output = result.stdout + result.stderr
        assert result.returncode == expected, f"종료코드 {result.returncode}, 기대값 {expected}\n{output}"
        assert swift_calls(root) == expected_calls, f"검사 범위 불일치: {swift_calls(root)}\n{output}"
        for note in notes:
            assert note in output, f"출력에 {note!r} 없음\n{output}"
        if expected == 2:
            assert "사용:" in output or "--changed" in output, "잘못된 인자에 사용법을 알리지 않음"
            return
        if case == "changed-reuse":
            assert len(list((root / ".build/check-logs").glob("run.*"))) == 1, "재사용인데 로그 폴더를 만듦"
            return
        if case == "changed-docs-checker":
            light = (root / "light-calls.txt").read_text().splitlines()
            assert light == ["check-prose.py --base synthetic-base"], f"문장 검사를 --changed 기준으로 부르지 않음: {light}"
        git_calls = (root / "git-calls.txt").read_text()
        if "--base" in arguments:
            base = arguments[arguments.index("--base") + 1]
            assert f"diff --name-only --no-renames -z {base}" in git_calls and "merge-base" not in git_calls, \
                f"준 기준을 그대로 쓰지 않음\n{git_calls}"
        else:
            assert "merge-base HEAD dev" in git_calls and "diff --name-only --no-renames -z synthetic-base" in git_calls, \
                f"기준을 dev와의 merge-base로 잡지 않음\n{git_calls}"
        runs = list((root / ".build/check-logs").glob("run.*"))
        assert len(runs) == 1, f"로그 폴더 수 {len(runs)}"
        run = runs[0]
        assert (run / "exit-code.txt").read_text().strip() == str(expected), "종료코드 보존 누락"
        assert (run / "affected.json").exists(), "고른 범위를 로그에 남기지 않음"
        summary = output.split("── 검사 요약", 1)[1] if "── 검사 요약" in output else ""
        assert summary and str(run) in summary or run.name in summary, f"요약·로그 폴더 누락\n{output}"
        if expected == 0:
            assert "✔ 통과" in summary, "통과 요약 누락"
        else:
            assert "✘" in summary, "실패 요약 누락"
        if case == "changed-test-fail":
            failure_part = summary
            assert "통과한_시험" not in failure_part, "요약에 통과한 시험까지 넣음"
        if case == "changed-write":
            assert "목표 60%" not in output and "코어" not in output, "부분 검사에서 코어 커버리지까지 판정함"
            assert "남은 필수 검사" in summary, "필수 검사 안내를 요약에 다시 내지 않음"
        if expected_calls and expected_calls[-1].startswith("test"):
            homes = {line.split("\t")[0] for line in (root / "env.txt").read_text().splitlines()}
            rekordbox = {line.split("\t")[1] for line in (root / "env.txt").read_text().splitlines()}
            assert all(h.startswith(str(run.resolve())) for h in homes | rekordbox), \
                f"임시 DJC_HOME·DJC_REKORDBOX_DIR을 주지 않음: {homes} {rekordbox}"
        info = (run / "run-info.txt").read_text()
        assert "mode=" + ("full" if case.startswith("changed-widen") else "changed") in info, info
        assert "requested=changed" in info, info



# 인자로 경우 이름의 일부를 주면 그것만 돈다(예: scripts/test-check.py affected changed). 인자가 없으면 전부.
ONLY = sys.argv[1:]


def selected(name):
    return not ONLY or any(part in name for part in ONLY)


def attempt(name, check, *arguments):
    try:
        check(*arguments)
        print(f"✔ {name}")
        return 0
    except (AssertionError, OSError, UnicodeError, ValueError, KeyError, re.error, StopIteration,
            subprocess.SubprocessError) as error:
        print(f"✘ {name}: {error}")
        return 1


runs = []
runs += [(case, check_affected, (case, *arguments)) for case, arguments in AFFECTED_CASES.items()]
runs += [(case, check_affected_extra, (case,)) for case in AFFECTED_EXTRA]
runs += [("affected-real-map", check_real_map, ())]
runs += [(case, check_real_safety, (case, *arguments)) for case, arguments in REAL_SAFETY_CASES.items()]
runs += [(case, check_reuse, (case,)) for case in REUSE_CASES]
runs += [(case, check_changed, (case, *arguments)) for case, arguments in CHANGED_CASES.items()]
runs += [(case, check_case, (case, expected)) for case, expected in CASES.items()]
runs += [(name, check_partition, arguments) for name, arguments in PARTITIONS.items()]
runs += [(name, check_imports, (name, *arguments)) for name, arguments in IMPORT_CASES.items()]
runs = [run for run in runs if selected(run[0])]
if not runs:
    print(f"고른 경우가 없습니다: {ONLY}")
    sys.exit(2)
failures = sum(attempt(name, check, *arguments) for name, check, arguments in runs)
total = len(runs)
print(f"검사 스크립트 회귀: {total}개 중 {total - failures}개 통과")
sys.exit(bool(failures))
