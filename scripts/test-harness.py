#!/usr/bin/env python3
"""하네스(.claude/settings.json·scripts/hooks/*·scripts/check-docs.py·scripts/check-prose.py·scripts/worker-lock.sh)를 표본 입력으로 시험한다.

훅에는 Claude Code가 주는 모양의 JSON을 표준 입력으로 넣고 종료 코드·출력을 본다. 실제 라이브러리·볼륨에는
아무것도 하지 않는다(막는 훅은 명령을 실행하지 않고 판정만 한다, 나머지는 임시 폴더에서).
사용: python3 scripts/test-harness.py [--quiet]   (--quiet: 실패 줄과 끝 줄만, scripts/check.sh가 부를 때)
"""
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
# 훅은 실제 홈 폴더 경로로 판정한다. 개인 경로를 저장소에 남기지 않게 실행 때 만든다
HOME = os.path.expanduser('~')

ROOT = Path(__file__).resolve().parent.parent
HOOKS = ROOT / "scripts/hooks"
CHECK_DOCS = ROOT / "scripts/check-docs.py"
CHECK_PROSE = ROOT / "scripts/check-prose.py"
WORKER_LOCK = ROOT / "scripts/worker-lock.sh"

# 막아야 하는 명령(라이브 rekordbox 폴더·실물 볼륨·디스크 장치에 대한 쓰기, --live·--allow-physical, 보호 경로가 든 코드 넘기기)
BLOCK = [
    # 1회차
    'rm -rf ~/Library/Pioneer/rekordbox/share',
    'rm -f "$HOME/Library/Pioneer/rekordbox/master.db-wal"',
    'cp /tmp/x.db ~/Library/Pioneer/rekordbox/master.db',
    'mv ~/Library/Pioneer/rekordbox/master.db /tmp/',
    'sqlite3 "$HOME/Library/Pioneer/rekordbox/master.db" .tables',
    "echo '{}' > ~/Library/Application\\ Support/Pioneer/rekordbox6/rekordbox3.settings",
    'touch ${HOME}/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/x',
    'echo hi > /Volumes/USB/a.txt',
    'rsync -a /tmp/x/ /Volumes/USB/',
    'ditto /tmp/PIONEER /Volumes/USB/PIONEER',
    'tee -a /Volumes/X/log < /tmp/a',
    'cd /Volumes/USB && rm -rf PIONEER',
    'cd /tmp\nrm -rf /Volumes/USB/x',
    'bash -c "rm -rf /Volumes/USB/x"',
    'ls /Volumes/USB | xargs rm',
    'ls /Volumes/USB | grep part | xargs -n 1 rm -f',
    'find /tmp/x -type f | xargs -I{} cp {} /Volumes/USB/',
    "find /Volumes/USB -name '._*' -delete",
    'dot_clean /Volumes/USB',
    'diskutil eraseVolume FAT32 X /Volumes/USB',
    "sqlite3 /Volumes/USB/PIONEER/rekordbox/exportLibrary.db 'select 1'",
    'dd if=/tmp/img of=/Volumes/USB/x bs=1m',
    "sed -i '' 's/a/b/' /Volumes/USB/PIONEER/x.xml",
    '.build/debug/djc usb-export --volume /Volumes/USB --db /tmp/a.db --playlist 1',
    '.build/debug/djc usb-edit --volume /Volumes/X --draft --db /tmp/a.db --allow-physical --confirm X',
    '.build/debug/djc usb-restore --volume /Volumes/X',
    '.build/debug/djc lab usb-image attach /tmp/a.img --mount /Volumes/X',
    '.build/debug/djc cue-write --live',
    'swift run djc track-delete --live 101',
    '.build/debug/djc snapshot-point restore --live 2026-10-09T00:00:00Z',
    'timeout 60 .build/debug/djc rekordbox-restore --db ~/Library/Pioneer/rekordbox/master.db --backup /tmp/b',
    'DJC_REKORDBOX_DIR=/tmp/rb .build/debug/djc cue-write --live',
    'export DJC_REKORDBOX_DIR=/tmp/rb; .build/debug/djc cue-write --live',
    'python3 -c \'print("/Volumes/X")\'',
    '.build/debug/djc cue-write --live --dry-run',
    # 리뷰 표본(167-work/reviews-harness/hx-docs-review.md)
    'cp /tmp/a.db ~/Library/Pioneer/rekordbox/master.db',
    'cp /tmp/a.db "$HOME/Library/Pioneer/rekordbox/master.db"',
    'mv /tmp/x /Volumes/MYUSB/x',
    'rm -rf /Volumes/MYUSB/PIONEER',
    'echo x > /Volumes/MYUSB/a.txt',
    'echo x 2>/Volumes/MYUSB/err.txt',
    'echo x | tee -a ~/Library/Pioneer/rekordbox/x',
    'sqlite3 /Volumes/MYUSB/PIONEER/rekordbox/exportLibrary.db "DELETE FROM x"',
    'rsync -a /tmp/src/ /Volumes/MYUSB/',
    'ditto /tmp/src /Volumes/MYUSB/dst',
    'python3 -c "open(\'/Volumes/MYUSB/a.txt\',\'w\').write(\'x\')"',
    'python3 -c "import shutil; shutil.copy(\'/tmp/a\', \'$HOME/Library/Pioneer/rekordbox/master.db\')"',
    "python3 - <<'EOF'\nimport os; os.remove('/Volumes/MYUSB/x')\nEOF",
    "bash <<'EOF'\nrm -rf /Volumes/MYUSB/PIONEER\nEOF",
    'eval "rm -rf /Volumes/MYUSB/PIONEER"',
    'perl -e \'unlink "/Volumes/MYUSB/x"\'',
    'D=.build/debug/djc; $D usb-export --volume /Volumes/MYUSB --db /tmp/s.db --playlist 1 --allow-physical --confirm MYUSB',
    '"$D" usb-edit --volume /Volumes/MYUSB --draft --db /tmp/s.db',
    '.build/debug/djc usb-export --volume /Volumes/MYUSB --db /tmp/s.db --playlist 1',
    'DJC_REKORDBOX_DIR=$HOME/Library/Pioneer/rekordbox .build/debug/djc cue-write --live',
    'diskutil eraseDisk FAT32 TEST MBR disk4',
    'diskutil eraseVolume FAT32 TEST /Volumes/MYUSB',
    'sudo dd if=/dev/zero of=/dev/rdisk4 bs=1m',
    'newfs_msdos -F 32 /dev/rdisk4s1',
    'cd ~/Library/Pioneer/rekordbox && rm master.db',
    'pushd /Volumes/MYUSB && rm -rf PIONEER',
    'cp /tmp/a.db ~/Library/pioneer/rekordbox/master.db',
    f'cp /tmp/a.db {HOME}//Library/Pioneer/rekordbox/master.db',
    'RB=~/Library/Pioneer/rekordbox; cp /tmp/a.db "$RB/master.db"',
    'ln -sfn /tmp/x ~/Library/Pioneer/rekordbox/share',
    "find /Volumes/MYUSB -name '._*' -delete",
    'tar xf /tmp/a.tar -C /Volumes/MYUSB',
    'osascript -e \'do shell script "rm -rf /Volumes/MYUSB/x"\'',
    '.build/debug/djc snapshot-point restore --live latest',
    'swift run djc track-delete --live --share ~/Library/Pioneer/rekordbox/share 123',
    'cp -R /tmp/copy/share/PIONEER ~/Library/Pioneer/rekordbox/share/',
    'install -m 644 /tmp/a /Volumes/MYUSB/a',
    'scp host:/a /Volumes/MYUSB/a',
    'cat /tmp/a >> "/Volumes/My USB/a.txt"',
    'cp /tmp/a /tmp/b /Volumes/MYUSB/',
    'cp -t /Volumes/MYUSB /tmp/a',
    "sed -i '' 's/a/b/' /Volumes/MYUSB/PIONEER/x.txt",
    'truncate -s 0 ~/Library/Pioneer/rekordbox/master.db-wal',
    'DJC_REKORDBOX_DIR=/tmp/copy .build/debug/djc cue-write --live',
    'if [ -d /Volumes/MYUSB ]; then cp /tmp/a /Volumes/MYUSB/; fi',
    'for f in a b; do cp /tmp/$f /Volumes/MYUSB/; done',
    '{ rm -rf /Volumes/MYUSB/PIONEER; }',
    'true && { cp /tmp/a ~/Library/Pioneer/rekordbox/master.db; }',
    '! rm /Volumes/MYUSB/x',
    'nice -n 10 cp /tmp/a /Volumes/MYUSB/',
    'timeout -s KILL 60 rm -rf /Volumes/MYUSB/x',
    'echo `rm -rf /Volumes/MYUSB/x`',
    'export DJC_REKORDBOX_DIR=; .build/debug/djc cue-write --live',
    'DJC_REKORDBOX_DIR=$COPY .build/debug/djc cue-write --live',
    'DJC_REKORDBOX_DIR="" .build/debug/djc snapshot-point restore --live latest',
    '.build/debug/djc usb-export --volume=/Volumes/MYUSB --db /tmp/s.db --playlist 1',
    'cd /Volumes && rm -rf MYUSB/PIONEER',
    'cd /Volumes/MYUSB/PIONEER && cd .. && rm -rf PIONEER',
    'ln -s ~/Library/Pioneer/rekordbox/share /tmp/copy/share',
    '.build/debug/djc lab tag-write-test --db ~/Library/Pioneer/rekordbox/master.db 123:Title=x',
    '.build/debug/djc lab analysis-attach-test --db ~/Library/Pioneer/rekordbox/master.db --share ~/Library/Pioneer/rekordbox/share 123',
    '.build/debug/djc lab gain-write-test ~/Library/Pioneer/rekordbox/master.db 123 -3',
    '.build/debug/djc lab artwork-write-test --db ~/Library/Pioneer/rekordbox/master.db 123 --delete',
    # 2회차
    'diskutil apfs deleteContainer disk4',
    'cat /tmp/img > /dev/rdisk4',
    'fdisk -i -y /dev/disk4',
    'gpt create disk4',
    'asr restore --source /tmp/a.dmg --target /Volumes/X --erase',
    'sudo diskutil partitionDisk disk4 1 MBR FAT32 X 100%',
    'diskutil zeroDisk disk4',
    'DJC_REKORDBOX_DIR=~/Library/Pioneer/rekordbox DJC_HOME=/tmp/h .build/debug/DJCrate --write-selftest',
    'export DJC_REKORDBOX_DIR=$HOME/Library/Pioneer/rekordbox',
    '.build/debug/djc lab grid-write-test ~/Library/Pioneer/rekordbox/master.db ~/Library/Pioneer/rekordbox/share UUID 128',
    '.build/debug/djc lab loop-repro --old /tmp/a --new /tmp/b --ids 1 --work ~/Library/Pioneer/rekordbox',
    ".build/debug/djc lab sql ~/Library/Pioneer/rekordbox/master.db 'SELECT 1'",
    '.build/debug/djc xml-export --db /tmp/c/master.db --out /Volumes/X/lib.xml --no-analysis',
    '.build/debug/djc track-add --live --analyze /tmp/a.mp3',
    '.build/debug/djc rekordbox-restore --backup /tmp/b --live',
    'echo "$(rm -rf /Volumes/X/y)"',
    'git commit -m "fix: `rm -rf /Volumes/X`"',
    'echo rm -rf /Volumes/X | bash',
    'bash <<< "rm -rf /Volumes/X"',
    "sh -c 'ls /Volumes/X'",
    'bash -lc "cp /tmp/a /Volumes/X/"',
    'cd ~/Library && rm -rf Pioneer',
    'rm -rf ~/Library',
    'mv ~/Library/Application\\ Support /tmp/x',
    "find ~/Library/Pioneer -name '*.tmp' -delete",
    "find /Volumes/X -name '*.mp3' -exec rm {} +",
    'find /Volumes/X -type f -exec mv {} /tmp/ \\;',
    'find /Volumes/X -type f -exec sh -c \'rm "$1"\' _ {} \\;',
    'ls /Volumes/X | xargs -I{} rm /Volumes/X/{}',
    'sudo -u root rm -rf /Volumes/X',
    'nohup rm -rf /Volumes/X &',
    '(cd /Volumes/X && rm -rf a)',
    'curl -o /Volumes/X/f https://example.com',
    'tar cf /Volumes/X/a.tar /tmp/src',
    'awk \'BEGIN{system("rm -rf /Volumes/X")}\'',
    'for f in /Volumes/MYUSB/*.txt; do rm "$f"; done',
    'case x in a) rm -rf /Volumes/X;; esac',
    'while true; do rm -rf /Volumes/X/tmp; done',
    'D=.build/debug/djc; $D lab grid-write-test ~/Library/Pioneer/rekordbox/master.db /tmp/s U 128',
    '${D} usb-migrate --volume /Volumes/X',
    '"${DJC}" usb-recover --volume /Volumes/X',
    'node -e "require(\'fs\').rmSync(\'/Volumes/X/a\')"',
    'ruby -e \'File.delete("/Volumes/X/a")\'',
    "perl -pi -e 's/a/b/' /Volumes/X/a.txt",
    'python3 -c "import shutil; shutil.rmtree(__import__(\'os\').path.expanduser(\'~/Library/Pioneer/rekordbox/share\'))"',
    "python3 - <<'EOF'\nimport os\nos.remove(os.path.expanduser('~/Library/Pioneer/rekordbox/master.db'))\nEOF",
    f'cp /tmp/a.db /{HOME}/Library/Pioneer/rekordbox/master.db',
    'cp /tmp/a /VOLUMES/MYUSB/a',
    f'cp /tmp/a /System/Volumes/Data{HOME}/Library/Pioneer/rekordbox/x',
    'time rm -rf /Volumes/X/a',
    'ln -s /Volumes/MYUSB/PIONEER /tmp/copy/PIONEER',
    'unzip /tmp/a.zip -d /Volumes/X',
    'ls /Volumes/X | xargs rm -f',
    'if true; then .build/debug/djc usb-export --volume /Volumes/X --db /tmp/s.db --playlist 1; fi',
    'exec > /Volumes/X/log',
    'gtimeout -k 5 60 rm -rf /Volumes/X',
    'caffeinate -i rm -rf /Volumes/X',
    'lockf -t 10 /tmp/l rm -rf /Volumes/X',
    'env -u FOO rm -rf /Volumes/X',
    'rsync -a /tmp/src/ /Volumes/X/ --exclude .DS_Store',
    'rsync -a /tmp/src/ /tmp/dst/ --log-file /Volumes/X/rsync.log',
    'find ~/Library -name "*.db" -delete',
    '.build/debug/djc usb-info /Volumes/X --allow-physical',
    'echo --allow-physical',
]
# 통과해야 하는 명령(읽기·사본 뜨기·djc 읽기 명령·빌드·시험·git·문서 쓰기)
ALLOW = [
    # 1회차
    'ls -la ~/Library/Pioneer/rekordbox',
    'stat ~/Library/Pioneer/rekordbox/master.db',
    'cp ~/Library/Pioneer/rekordbox/master.db /tmp/x.db',
    'cp -R /Volumes/USB/PIONEER /tmp/copy',
    'ls /Volumes',
    'cd /Volumes/USB && ls',
    '.build/debug/djc usb-info /Volumes/USB --json',
    '.build/debug/djc usb-export --volume /Volumes/USB --db /tmp/a.db --playlist 1 --dry-run',
    '.build/debug/djc lab usb-image info /Volumes/X',
    'DJC_HOME=$(mktemp -d) .build/debug/djc snapshot',
    '.build/debug/djc snapshot-point create --live',
    '.build/debug/djc cue-write --db /tmp/copy/master.db --dry-run',
    'git status && git diff --stat',
    'git log --oneline -- ~/Library/Pioneer',
    'lockf /tmp/djc-heavy.lock scripts/check.sh --changed',
    "scripts/check.sh --quick --filter 'LoopPlannerTests'",
    'swift build',
    'grep -rn Pioneer Sources | head',
    'diskutil list',
    "cat > /tmp/doc.md <<'EOF'\nrm -rf /Volumes/USB\ndjc cue-write --live\nEOF",
    'ls /Volumes/USB/PIONEER | xargs -I{} cp /Volumes/USB/PIONEER/{} /tmp/copy/',
    "git commit -m 'docs: rm -rf /Volumes/USB 같은 명령을 막는 훅'",
    '.build/debug/djc snapshot-point list --live',
    # 리뷰 표본(167-work/reviews-harness/hx-docs-review.md)
    'git log --oneline -5 -- Sources/RekordboxKit',
    'swift build 2>&1 | tail -5',
    'DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=/tmp/copy swift test --filter WriteGuardTests > /tmp/log 2>&1',
    "scripts/check.sh --quick --filter 'WriteGuardTests' > /tmp/check.log 2>&1",
    'scripts/check.sh --changed',
    '.build/debug/djc snapshot',
    '.build/debug/djc snapshot --force',
    'cp -R ~/Library/Pioneer/rekordbox /tmp/copy',
    'cp -c "$HOME/Library/Pioneer/rekordbox/master.db" /tmp/copy/master.db',
    'rsync -a ~/Library/Pioneer/rekordbox/share/ /tmp/copy/share/',
    'ditto ~/Library/Pioneer/rekordbox /tmp/copy',
    'stat /Volumes/MYUSB',
    "find /Volumes/MYUSB -name '*.pdb'",
    'find /Volumes/MYUSB -type f -exec shasum -a 256 {} +',
    "find ~/Library/Pioneer/rekordbox -name 'master.db*' -exec cp {} /tmp/copy/ \\;",
    'hdiutil info',
    'diskutil info /Volumes/MYUSB',
    'ls /Volumes > /tmp/vols.txt',
    'rm -rf .build/check-logs/run.X && mv a.txt b.txt',
    'rsync -a ~/Library/Pioneer/rekordbox/share/ /tmp/copy/share/ --exclude .DS_Store',
    'find . -name "*.orig" -delete',
    'git rm --cached ~/Library/Pioneer/x',
    'W=$(mktemp -d); DJC_HOME=$W .build/debug/djc usb-export --volume $DJC_HOME/mnt --db /tmp/s.db --playlist 1',
    'DJC_HOME=/tmp/w .build/debug/djc usb-export --volume /tmp/w/mnt --db /tmp/s.db --playlist 1',
    '.build/debug/djc usb-info /Volumes/MYUSB --json > /tmp/info.json',
    '.build/debug/djc usb-export --volume /Volumes/MYUSB --db /tmp/s.db --playlist 1 --dry-run',
    '.build/debug/djc compat',
    '.build/debug/djc cue-write --db /tmp/copy/master.db',
    'cat ~/Library/Pioneer/rekordbox/masterPlaylists6.xml | head',
    'grep -r "Pioneer" docs/ | head',
    'rg -n "/Volumes/" Sources | wc -l',
    'echo "~/Library/Pioneer 는 라이브 폴더" > /tmp/note.txt',
    "cat > /tmp/doc.md <<'EOF'\nrm -rf /Volumes/MYUSB\nEOF",
    'git commit -m "docs: /Volumes 쓰기 금지 설명"',
    'gh issue view 12 | grep Pioneer',
    'shasum -a 256 /Volumes/MYUSB/PIONEER/rekordbox/export.pdb > /tmp/sum.txt',
    'cp /Volumes/MYUSB/PIONEER/rekordbox/exportLibrary.db /tmp/usbcopy/',
    'rsync -a /Volumes/MYUSB/PIONEER/ /tmp/usbcopy/',
    'python3 -c "import os; print(os.listdir(\'/Volumes\'))"',
    '.build/debug/djc lab usb-image info /tmp/w/a.dmg',
    '.build/debug/djc lab usb-tree /Volumes/MYUSB',
    '.build/debug/djc lab usb-diff /Volumes/MYUSB /tmp/w/mnt --onelibrary',
    'tar cf /tmp/a.tar -C ~/Library/Pioneer/rekordbox share',
    'ls /Volumes/MYUSB | xargs -I{} echo {}',
    'mkdir -p /tmp/copy && cp -R ~/Library/Pioneer/rekordbox/share /tmp/copy/',
    'xattr -l /Volumes/MYUSB/x',
    'cd /Volumes/MYUSB && ls -la',
    'cd /Volumes/MYUSB && shasum -a 256 PIONEER/rekordbox/export.pdb > /tmp/s.txt',
    'cd ~/Library/Pioneer/rekordbox && cp master.db /tmp/copy/',
    'cd ~/Library/Pioneer/rekordbox && tar cf /tmp/a.tar share',
    'hdiutil attach -nomount /tmp/w/a.dmg',
    '.build/debug/djc rekordbox-restore --db /tmp/copy/master.db --backup /tmp/w/b',
    'scripts/build-app.sh --install',
    'ls /Volumes/MYUSB/PIONEER | head',
    'for f in /Volumes/MYUSB/PIONEER/rekordbox/*; do shasum "$f"; done',
    'if [ -d /Volumes/MYUSB ]; then ls /Volumes/MYUSB; fi',
    'echo /Volumes/MYUSB | xargs -I{} ls {}',
    'cd /Volumes/MYUSB && cd /tmp && rm -rf work',
    'cd ~/Library/Pioneer/rekordbox && cd - && rm -rf /tmp/x',
    f'cd ~/Library/Pioneer/rekordbox; cd {HOME}/dev/DJCrate; rm -f .build/x',
    'cd ~/Library/Pioneer/rekordbox && mkdir -p /tmp/copy && cp master.db /tmp/copy/',
    "cd /Volumes/MYUSB && find . -name '*.pdb' > /tmp/pdbs.txt",
    'cd ~/Library/Pioneer/rekordbox && rsync -a share /tmp/copy/',
    'timeout 120 .build/debug/DJCrate --db /tmp/w/rb/master.db --usb-selftest > /tmp/usb.log 2>&1',
    'DJC_HOME=/tmp/w timeout 300 .build/debug/djc lab usb-image attach /tmp/w/a.dmg --mount /tmp/w/mnt',
    'grep -rn "/Volumes/" Sources > /tmp/hits.txt',
    'echo "cp x /Volumes/Y" | pbcopy',
    'gh issue comment 12 --body "rm -rf /Volumes/X 같은 명령은 훅이 막는다"',
    'git commit -m "fix: /Volumes 쓰기 금지" -m "rm -rf /Volumes/X는 막는다"',
    'python3 scripts/test-harness.py --quiet',
    "find /Volumes/MYUSB -name '._*' -print",
    'ls -la /Volumes/MYUSB/PIONEER > ~/Desktop/list.txt',
    'mkdir -p /tmp/rb && cp -c ~/Library/Pioneer/rekordbox/master.db* /tmp/rb/',
    '.build/debug/djc compat --db ~/Library/Pioneer/rekordbox/master.db',
    'ls /Volumes/MYUSB/PIONEER | xargs -I{} mkdir -p /tmp/out/{}',
    "find /Volumes/MYUSB -name '*.mp3' | xargs -I{} cp {} /tmp/out/",
    "find ~/Library/Pioneer/rekordbox/share -name 'ANLZ0000.EXT' -exec ls -la {} \\;",
    "find /Volumes/MYUSB -type f -newer /tmp/stamp -exec stat -f '%N %z' {} +",
    # 2회차
    "find /Volumes/MYUSB -name '*.pdb' -print0 | xargs -0 shasum",
    'mkdir -p /tmp/copy && cp -R ~/Library/Pioneer/rekordbox /tmp/copy/',
    '.build/debug/djc xml-export --db /tmp/c/master.db --out /tmp/lib.xml --share ~/Library/Pioneer/rekordbox/share',
    '.build/debug/djc xml-diff --db /tmp/c/master.db --xml /tmp/a.xml --share ~/Library/Pioneer/rekordbox/share',
    '.build/debug/djc lab setting-export --local ~/Library/Application\\ Support/Pioneer/rekordbox6 --out /tmp/w/s',
    '.build/debug/djc snapshot-point diff 3 --live',
    '.build/debug/djc snapshot-point pin 3 --live',
    'diskutil info disk4',
    'diskutil eject /Volumes/X',
    'gpt -r show disk4',
    'fdisk /dev/disk4',
    'dd if=/dev/rdisk4 of=/tmp/img bs=1m count=1',
    'python3 -c "print(1)"',
    "python3 - <<'EOF'\nprint(open('/tmp/x').read())\nEOF",
    "cat > /tmp/doc.md <<'EOF'\nrm -rf /Volumes/X\npython3 -c 'x'\nEOF",
    "git commit -F - <<'EOF'\nrm -rf /Volumes/X\nEOF",
    'gh pr create --title t --body "$(cat <<\'EOF\'\nrm -rf /Volumes/X 를 막는다\nEOF\n)"',
    "git commit -m 'fix: `rm -rf /Volumes/X`를 막는다'",
    'DJC_HOME=$(mktemp -d) DJC_REKORDBOX_DIR=/tmp/copy .build/debug/DJCrate --db /tmp/copy/master.db --write-selftest',
    'echo hi > /tmp/x 2>&1',
    '.build/debug/djc usb-export --volume=/tmp/w/mnt --db /tmp/s.db --playlist 1',
    'DJC_HOME=/tmp/w .build/debug/djc lab usb-image create /tmp/w/a.dmg --size 1g',
    'cd /Volumes/MYUSB/PIONEER && cd /tmp && rm -rf work',
    'rm -rf ~/Library/Caches/DJCrate-test',
    'tar cf /tmp/a.tar -C /Volumes/MYUSB PIONEER',
    'unzip /tmp/a.zip -d /tmp/out',
    'curl -o /tmp/f https://example.com/Volumes/x',
    'for f in /Volumes/MYUSB/PIONEER/*; do shasum "$f"; done',
    'while read f; do echo "$f"; done < /tmp/list',
    'scripts/check.sh --changed --base 0123abc',
]

# 지금 폴더(훅 입력의 cwd)를 따라 상대 경로를 푸는 경우: (cwd, 명령, 기대 종료 코드)
CWD_CASES = [
    ("/Volumes/MYUSB", "rm -rf PIONEER", 2),
    ("/Volumes/MYUSB", "touch a", 2),
    ("/Volumes/MYUSB", "ls -la", 0),
    ("/Volumes/MYUSB", "shasum -a 256 PIONEER/rekordbox/export.pdb > /tmp/s.txt", 0),
    ("/Volumes/MYUSB", "cd /tmp && rm -rf a", 0),
    ("/Volumes/MYUSB", "unzip -l /tmp/a.zip", 0),
    ("/Volumes/MYUSB", "unzip /tmp/a.zip", 2),
    (str(Path.home() / "Library/Pioneer/rekordbox"), "cp master.db /tmp/copy/", 0),
    (str(Path.home() / "Library/Pioneer/rekordbox"), "rm master.db-wal", 2),
]
# 알려진 한계(.claude/rules/harness.md): 지금은 통과한다. 막게 되면 이 목록에서 BLOCK으로 옮긴다
LIMITS = [
    "git clone /tmp/repo /Volumes/MYUSB/repo",
    "X=$(echo /Volumes/MYUSB); rm -rf \"$X/a\"",
    "while read f; do rm \"$f\"; done < /tmp/usb-files.txt",
    "python3 scripts/some-tool.py /Volumes/MYUSB/a",
    "bash ./write.sh /Volumes/MYUSB",
]


def run(command, payload, env=None, cwd=None):
    return subprocess.run([sys.executable, *command], input=json.dumps(payload), capture_output=True, text=True,
                          timeout=120, env=env, cwd=cwd)


def bash_payload(command):
    return {"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": str(ROOT),
            "tool_input": {"command": command, "description": "시험"}}


def case_guard(command, expected, cwd=None):
    payload = bash_payload(command)
    if cwd:
        payload["cwd"] = cwd
    result = run([str(HOOKS / "guard-bash.py")], payload)
    assert result.returncode == expected, f"종료 코드 {result.returncode}(기대 {expected}): {command!r} {result.stderr}"
    if expected == 2:
        assert "막음" in result.stderr and ("사본" in result.stderr or "디스크 이미지" in result.stderr), "막은 이유가 없음"
    else:
        assert not result.stdout and not result.stderr, "통과인데 출력이 있음"


def case_guard_other_tool():
    payload = {"hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": {"file_path": "/Volumes/X/a"}}
    assert run([str(HOOKS / "guard-bash.py")], payload).returncode == 0
    broken = subprocess.run([sys.executable, str(HOOKS / "guard-bash.py")], input="not json", capture_output=True,
                            text=True, timeout=10)
    assert broken.returncode == 0, "깨진 입력은 통과시켜야 함"


def fake_repo(folder, stub_exit, stub_lines=()):
    (folder / "scripts").mkdir(parents=True)
    (folder / "Package.swift").write_text("// swift-tools-version: 6.2\n")
    body = "import sys\n" + "".join(f"print({line!r})\n" for line in stub_lines) + f"sys.exit({stub_exit})\n"
    (folder / "scripts/check-imports.py").write_text(body)
    (folder / "Sources/DJCDomain").mkdir(parents=True)
    (folder / "docs").mkdir()


def edit_payload(path):
    return {"hook_event_name": "PostToolUse", "tool_name": "Edit", "tool_input": {"file_path": str(path)},
            "tool_response": {"filePath": str(path)}}


def case_imports(stub_exit, file_name, expected, expect_text=None):
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        fake_repo(repo, stub_exit, ["모듈 경계 규칙: 위반 1개", "✘ 새 위반: Sources/DJCApplication/A.swift\timport\tRekordboxKit"])
        result = run([str(HOOKS / "check-imports-after-edit.py")], edit_payload(repo / file_name))
        assert result.returncode == expected, f"종료 코드 {result.returncode}(기대 {expected}) {result.stderr}"
        if expect_text:
            assert expect_text in result.stderr, f"위반 줄이 없음: {result.stderr}"
            assert "모듈 경계 규칙: 위반 1개" not in result.stderr, "요약 줄까지 냄(위반 줄만 내야 함)"
        if expected == 0:
            assert not result.stdout and not result.stderr, "통과인데 출력이 있음"


def case_imports_real():
    started = time.monotonic()
    result = run([str(HOOKS / "check-imports-after-edit.py")], edit_payload(ROOT / "Sources/DJCDomain/Playback/LoopPlanner.swift"))
    assert result.returncode == 0 and not result.stderr, f"이 저장소의 경계 검사가 통과하지 않음: {result.stderr}"
    assert time.monotonic() - started < 30, "경계 검사가 너무 오래 걸림"


def case_imports_moved(source=None):
    """폴더를 옮겨 어느 타깃에도 속하지 않게 된 Swift 파일을 고치면 훅이 바로 알린다(실제 check-imports, 캐시한 패키지 타깃)."""
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        (repo / "scripts").mkdir()
        shutil.copy(source or ROOT / "scripts/check-imports.py", repo / "scripts/check-imports.py")
        (repo / "scripts/import-debt.txt").write_text("# 빚 없음\n")
        manifest = "// swift-tools-version: 6.2\n"
        (repo / "Package.swift").write_text(manifest)
        # dump-package를 부르지 않게 Package.swift 해시의 캐시를 미리 둔다.
        dump = {"targets": [{"name": "DJCDomain", "type": "regular", "dependencies": []},
                            {"name": "DJCTestKit", "type": "regular", "path": "Tests/Support/Kit", "dependencies": []}]}
        cache = repo / ".build/check-imports" / f"package-{hashlib.sha256(manifest.encode()).hexdigest()[:16]}.json"
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps(dump))
        for relative in ("Sources/DJCDomain/A.swift", "Tests/Support/Kit/K.swift", "Tests/Support/Moved/Fake.swift"):
            (repo / relative).parent.mkdir(parents=True, exist_ok=True)
            (repo / relative).write_text("import Foundation\n")
        result = run([str(HOOKS / "check-imports-after-edit.py")], edit_payload(repo / "Tests/Support/Moved/Fake.swift"))
        assert result.returncode == 2, f"종료 코드 {result.returncode}(기대 2) {result.stderr}"
        assert "어느 타깃에도 속하지 않는 Swift 파일입니다: Tests/Support/Moved/Fake.swift" in result.stderr, result.stderr


def git(repo, *arguments):
    subprocess.run(["git", "-C", str(repo), *arguments], check=True, capture_output=True, timeout=20)


def stop_repo(folder, tree_script=True):
    git(folder, "init", "-q")
    git(folder, "config", "user.email", "t@example.com")
    git(folder, "config", "user.name", "t")
    (folder / "scripts").mkdir()
    (folder / "scripts/check.sh").write_text("#!/bin/zsh\n")
    if tree_script:
        # 작업 트리 해시 대신 .tree 파일 내용을 낸다(없으면 실패)
        (folder / "scripts/affected-tests.py").write_text(
            "import sys, pathlib\nf = pathlib.Path('.tree')\nprint(f.read_text().strip()) if f.exists() else sys.exit(1)\n")
    (folder / "Sources/A").mkdir(parents=True)
    (folder / "Sources/A/A.swift").write_text("let a = 1\n")
    (folder / "docs").mkdir()
    (folder / "docs/a.md").write_text("a\n")
    (folder / ".gitignore").write_text(".build/\n.tree\n")
    git(folder, "add", "-A")
    git(folder, "commit", "-qm", "base")
    (folder / ".build/check-logs").mkdir(parents=True)


def stop_payload(folder, active=False):
    return {"hook_event_name": "Stop", "cwd": str(folder), "stop_hook_active": active, "last_assistant_message": "끝"}


def pass_line(mode, tree, log="/tmp/run.X", scope=None, base="none"):
    """scripts/check.sh 통과 기록 한 줄(record_pass와 같은 칸·순서). scope=None이면 scope·base 칸이 없던 옛 줄"""
    line = (f"v=1\tmode={mode}\tfilter=none\thead=abc\ttree={tree}\tkey=k\tlog={log}\tseconds=3"
            f"\ttime=2026-10-09T00:00:00Z\tcover=c\trequested={mode}")
    return line + (f"\tscope={scope}\tbase={base}" if scope else "") + "\n"


# scripts/check.sh --changed가 실제로 쓴 줄(2026-10-09 hx-r3, 경로·해시만 바꿈). 형식이 바뀌면 이 줄도 고친다
REAL_CHANGED_LINE = ("v=1\tmode=changed\tfilter=^(?:djcTests\\.[^/]+|RekordboxKitTests\\.(?:WriteGuardTests))/\thead=cfcd45f"
                     "\ttree={tree}\tkey=0f3c\tlog=/repo/.build/check-logs/run.Ab12Cd\tseconds=97\ttime=2026-10-09T12:00:00Z"
                     "\tcover=none\trequested=changed\tscope={scope}\tbase=3c1e1bb9ced1c213f2c3937f6189649e76dd213a\n")


# Stop 경우: (이름, last-pass, pass-history, 지금 트리, Swift 변경, stop_hook_active, affected-tests.py 있음, 경고 기대)
STOP_CASES = [
    ("통과 기록 없음 → 조용히", None, None, "T1", True, False, True, False),
    ("기록 형식 다름 → 조용히", "통과\n", None, "T1", True, False, True, False),
    ("같은 트리의 changed 통과 → 조용히", pass_line("changed", "T1"), None, "T1", True, False, True, False),
    ("같은 트리의 full 통과 → 조용히", pass_line("full", "T1"), None, "T1", True, False, True, False),
    ("같은 트리의 changed 통과(새 칸 scope=tests) → 조용히", pass_line("changed", "T1", scope="tests", base="B"), None, "T1",
     True, False, True, False),
    ("check.sh가 쓴 실제 changed 줄 → 조용히", REAL_CHANGED_LINE.format(tree="T1", scope="tests"), None, "T1",
     True, False, True, False),
    # 빌드·시험 없이 가벼운 검사만 돈 --changed(기준이 이미 Swift 변경을 품은 경우)는 Swift 검증이 아니다
    ("같은 트리의 changed 통과가 scope=none뿐 → 경고", REAL_CHANGED_LINE.format(tree="T1", scope="none"), None, "T1",
     True, False, True, True),
    ("같은 트리의 full 통과(scope=full) → 조용히", pass_line("full", "T1", scope="full"), None, "T1", True, False, True, False),
    ("같은 트리의 quick 통과뿐 → 경고", pass_line("quick", "T1"), None, "T1", True, False, True, True),
    ("같은 트리의 coverage 통과뿐 → 경고", pass_line("coverage", "T1"), None, "T1", True, False, True, True),
    ("다른 트리의 changed 통과 → 경고", pass_line("changed", "T0"), None, "T1", True, False, True, True),
    ("마지막은 quick, 이력에 같은 트리 changed → 조용히", pass_line("quick", "T1"),
     pass_line("changed", "T1") + pass_line("quick", "T1"), "T1", True, False, True, False),
    ("Swift 변경 없음(문서만) → 조용히", pass_line("quick", "T1"), None, "T1", False, False, True, False),
    ("stop_hook_active → 조용히", pass_line("quick", "T1"), None, "T1", True, True, True, False),
    ("affected-tests.py 없음 → 조용히", pass_line("quick", "T1"), None, "T1", True, False, False, False),
    ("트리 해시 실패 → 조용히", pass_line("quick", "T1"), None, None, True, False, True, False),
]


def case_stop(last, history, tree, swift_changed, active, tree_script, expect_warning):
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        stop_repo(repo, tree_script)
        logs = repo / ".build/check-logs"
        if last is not None:
            (logs / "last-pass").write_text(last)
        if history is not None:
            (logs / "pass-history").write_text(history)
        if tree is not None:
            (repo / ".tree").write_text(tree + "\n")
        if swift_changed:
            (repo / "Sources/A/A.swift").write_text("let a = 2\n")
        else:
            (repo / "docs/a.md").write_text("b\n")
        env = {k: v for k, v in os.environ.items() if k != "DJC_CHECK_LOG_ROOT"}
        result = run([str(HOOKS / "stop-verify-reminder.py")], stop_payload(repo, active), env=env)
        assert result.returncode == 0, f"Stop 훅은 막지 않아야 함(종료 코드 {result.returncode})"
        if expect_warning:
            data = json.loads(result.stdout)
            assert set(data) == {"systemMessage"}, f"systemMessage만 내야 함: {data}"
            assert "scripts/check.sh --changed" in data["systemMessage"], "--changed 권고가 없음"
        else:
            assert not result.stdout.strip() and not result.stderr.strip(), f"조용해야 함: {result.stdout}{result.stderr}"


def case_stop_outside_repo():
    with tempfile.TemporaryDirectory() as temp:
        result = run([str(HOOKS / "stop-verify-reminder.py")], stop_payload(Path(temp)))
        assert result.returncode == 0 and not result.stdout.strip(), "저장소 밖에서는 조용해야 함"


def case_session(has_section):
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        text = "# AGENTS\n\n소개\n\n"
        if has_section:
            text += "## 안전 불변식\n\n- 라이브러리에 쓰지 않는다.\n- 사본에만 쓴다.\n\n"
        text += "## 명령\n\n- 빌드\n"
        (folder / "AGENTS.md").write_text(text)
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(folder))
        payload = {"hook_event_name": "SessionStart", "source": "compact", "cwd": str(folder)}
        result = run([str(HOOKS / "session-safety.py")], payload, env=env)
        assert result.returncode == 0
        if has_section:
            assert "사본에만 쓴다" in result.stdout and "## 명령" not in result.stdout, f"절만 실어야 함: {result.stdout}"
        else:
            assert not result.stdout.strip(), "절이 없으면 조용해야 함"


def case_session_real():
    env = dict(os.environ, CLAUDE_PROJECT_DIR=str(ROOT))
    result = run([str(HOOKS / "session-safety.py")], {"hook_event_name": "SessionStart", "source": "compact"}, env=env)
    assert result.returncode == 0 and "## 안전 불변식" in result.stdout, "이 저장소 AGENTS.md의 안전 절을 싣지 못함"
    assert len(result.stdout) < 10000, "SessionStart 맥락 상한(10,000자)을 넘음"


def case_settings():
    data = json.loads((ROOT / ".claude/settings.json").read_text())
    hooks = data["hooks"]
    assert set(hooks) == {"PreToolUse", "PostToolUse", "Stop", "SessionStart"}, f"훅 이벤트: {set(hooks)}"
    assert hooks["PreToolUse"][0]["matcher"] == "Bash"
    assert "Edit" in hooks["PostToolUse"][0]["matcher"].split("|") and "Write" in hooks["PostToolUse"][0]["matcher"].split("|")
    assert "matcher" not in hooks["Stop"][0], "Stop은 matcher를 받지 않는다"
    assert hooks["SessionStart"][0]["matcher"] == "compact"
    for event, groups in hooks.items():
        for group in groups:
            for hook in group["hooks"]:
                assert hook["type"] == "command"
                script = re.search(r"\$CLAUDE_PROJECT_DIR/([\w./-]+)", hook["command"])
                assert script, f"{event}: 명령이 $CLAUDE_PROJECT_DIR 기준이 아님"
                assert (ROOT / script.group(1)).is_file(), f"{event}: 훅 스크립트가 없음 {script.group(1)}"
                assert "|| exit 0" in hook["command"], f"{event}: 스크립트가 없을 때 조용히 통과하지 않음"
    deny = data["permissions"]["deny"]
    assert all(rule.startswith("Edit(") for rule in deny), "파일 쓰기 거부는 Edit 규칙으로(Write 규칙은 보지 않는다)"
    for needed in ("~/Library/Pioneer/**", "//Volumes/**", "~/Library/Application Support/DJCrate/**"):
        assert f"Edit({needed})" in deny, f"거부 규칙 빠짐: {needed}"
    for rule in data["permissions"]["allow"]:
        assert rule.startswith("Bash("), f"허용은 Bash 읽기·검사 명령만: {rule}"
        assert not re.search(r"\b(rm|mv|cp|sudo|djc)\b", rule), f"허용에 쓰기 명령: {rule}"


def hook_commands():
    data = json.loads((ROOT / ".claude/settings.json").read_text())
    return {event: groups[0]["hooks"][0]["command"] for event, groups in data["hooks"].items()}


def case_settings_commands_run():
    """settings.json의 명령 글을 /bin/sh로 그대로 돌린다: 이 저장소에서는 훅이 돌고, 스크립트가 없는 폴더에서는 조용히 0."""
    commands = hook_commands()
    block = bash_payload("rm -rf /Volumes/MYUSB/PIONEER")
    real = subprocess.run(["/bin/sh", "-c", commands["PreToolUse"]], input=json.dumps(block), capture_output=True,
                          text=True, timeout=30, env=dict(os.environ, CLAUDE_PROJECT_DIR=str(ROOT)))
    assert real.returncode == 2 and "막음" in real.stderr, f"이 저장소에서 PreToolUse가 막지 않음: {real.returncode}"
    with tempfile.TemporaryDirectory() as temp:
        for event, command in commands.items():
            result = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(block), capture_output=True, text=True,
                                    timeout=30, env=dict(os.environ, CLAUDE_PROJECT_DIR=temp))
            assert result.returncode == 0 and not result.stdout and not result.stderr, \
                f"{event}: 훅 스크립트가 없는데 조용히 통과하지 않음(종료 코드 {result.returncode})"


def load_guard():
    sys.dont_write_bytecode = True  # 저장소에 __pycache__를 남기지 않는다
    spec = importlib.util.spec_from_file_location("guard_bash", HOOKS / "guard-bash.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def case_guard_names():
    """훅이 아는 djc 명령 이름이 소스 등록(Command("…"))에 모두 있는지(이름을 바꾸면 훅 목록도 고친다)."""
    registered, lab = set(), set()
    for source in (ROOT / "Sources/djc").rglob("*.swift"):
        names = set(re.findall(r'Command\(\s*"([a-z0-9][a-z0-9-]*)"', source.read_text(encoding="utf-8")))
        (lab if "/Lab/" in source.as_posix() else registered).update(names)
    guard = load_guard()
    top = guard.DJC_COMMANDS | guard.DJC_READ | guard.RB_WRITE_COMMANDS | guard.USB_WRITE_COMMANDS
    assert top <= registered, f"등록되지 않은 djc 명령: {sorted(top - registered)}"
    assert registered <= guard.DJC_COMMANDS, f"훅의 DJC_COMMANDS에 없는 djc 명령(읽기면 DJC_READ에도): {sorted(registered - guard.DJC_COMMANDS)}"
    lab_names = guard.LAB_READ | guard.USB_LAB_WRITES
    assert lab_names <= lab, f"등록되지 않은 djc lab 명령: {sorted(lab_names - lab)}"


# check-docs.py 경우: (이름, 꾸미기 함수, 기대 종료 코드, 출력에 있어야 할 글)
def docs_repo(folder):
    (folder / "Sources/djc/Commands").mkdir(parents=True)
    (folder / "Sources/djc/Commands/Main.swift").write_text('Command("snapshot", nil, "", run)\nCommand("usb-info", nil, "", run)\n')
    (folder / "Sources/DJCDomain").mkdir(parents=True)
    (folder / "Sources/DJCDomain/A.swift").write_text("")
    (folder / "scripts").mkdir()
    (folder / "scripts/check.sh").write_text("")
    (folder / "scripts/affected-tests.py").write_text("")
    (folder / "docs").mkdir()
    (folder / "docs/guide.md").write_text("# 안내\n\n## 검증 단계(`--changed`)\n\n글\n")
    (folder / ".claude/rules").mkdir(parents=True)
    (folder / ".claude/rules/domain.md").write_text('---\npaths:\n  - "Sources/DJCDomain/**"\n---\n\n# 규칙\n')
    (folder / ".claude/skills/verify").mkdir(parents=True)
    (folder / ".claude/skills/verify/SKILL.md").write_text("---\nname: verify\ndescription: 검증할 때 쓴다\n---\n\n본문\n")
    (folder / ".claude/agents").mkdir()
    (folder / ".claude/agents/reviewer.md").write_text("---\nname: reviewer\ndescription: 리뷰\ntools: Read, Grep\n---\n\n본문\n")
    (folder / "CLAUDE.md").write_text("@AGENTS.md\n")
    (folder / "AGENTS.md").write_text(
        "# AGENTS\n\n- `scripts/check.sh`, `Sources/DJCDomain/`, `scripts/affected-tests.py`\n"
        "- `djc snapshot`, `.build/debug/djc usb-info`\n- [안내](docs/guide.md#검증-단계--changed)\n")


def append(path, text):
    path.write_text(path.read_text() + text)


DOCS_CASES = [
    ("문서: 맞는 저장소", lambda f: None, 0, None),
    ("문서: 없는 경로", lambda f: append(f / "AGENTS.md", "- `Sources/Nope/X.swift`\n"), 1, "없는 저장소 경로: Sources/Nope/X.swift"),
    ("문서: 글롭이 맞는 파일 없음", lambda f: append(f / "AGENTS.md", "- `Sources/**/Zzz*.swift`\n"), 1, "없는 저장소 경로"),
    ("문서: 없는 스크립트", lambda f: append(f / ".claude/rules/domain.md", "`scripts/nope.sh`\n"), 1, "scripts/nope.sh"),
    ("문서: 없는 djc 명령", lambda f: append(f / "AGENTS.md", "```\n.build/debug/djc lab nope-cmd\n```\n"), 1, "djc lab nope-cmd"),
    ("문서: 경로를 붙인 djc의 없는 명령", lambda f: append(f / ".claude/skills/verify/SKILL.md",
                                                  "```\nDJC_HOME=/tmp/w ./.build/release/djc lab nope-two\n```\n"), 1, "djc lab nope-two"),
    ("문서: docs의 없는 djc 명령", lambda f: append(f / "docs/guide.md", "`djc frobnicate`\n"), 1, "djc frobnicate"),
    ("문서: 규칙 paths가 안 맞음", lambda f: (f / ".claude/rules/x.md").write_text('---\npaths:\n  - "Sources/Gone/**"\n---\n'), 1, "paths 글롭"),
    ("문서: 규칙 머리 깨짐", lambda f: (f / ".claude/rules/x.md").write_text('---\npaths:\n  - "Sources/DJCDomain/**"\n'), 1, "머리를 읽을 수 없습니다"),
    ("문서: 규칙 머리 없음", lambda f: (f / ".claude/rules/x.md").write_text("# 늘 실리는 규칙\n"), 1, "paths 머리가 없습니다"),
    ("문서: 깨진 링크 파일", lambda f: append(f / "AGENTS.md", "- [x](docs/nope.md)\n"), 1, "없는 파일"),
    ("문서: 깨진 링크 제목", lambda f: append(f / "AGENTS.md", "- [x](docs/guide.md#없는-제목)\n"), 1, "#없는-제목"),
    ("문서: 같은 문서 제목 링크", lambda f: append(f / "docs/guide.md", "[위](#안내)\n"), 0, None),
    ("문서: 없을 수도 있는 Package.resolved", lambda f: append(f / "AGENTS.md", "- `Package.resolved`\n"), 0, None),
    ("문서: 스킬 이름이 폴더와 다름", lambda f: (f / ".claude/skills/verify/SKILL.md").write_text("---\nname: other\ndescription: d\n---\n"), 1, "폴더 이름"),
    ("문서: 스킬 설명 없음", lambda f: (f / ".claude/skills/verify/SKILL.md").write_text("---\nname: verify\n---\n"), 1, "description"),
    ("문서: 스킬 본문 500줄", lambda f: (f / ".claude/skills/verify/SKILL.md").write_text("---\nname: verify\ndescription: d\n---\n" + "줄\n" * 500), 1, "500줄"),
    ("문서: 에이전트 설명 없음", lambda f: (f / ".claude/agents/reviewer.md").write_text("---\nname: reviewer\n---\n"), 1, "name·description"),
    ("문서: CLAUDE.md 가져오기 없음", lambda f: (f / "CLAUDE.md").write_text("@NOPE.md\n"), 1, "가져오는 파일"),
    ("문서: AGENTS.md 12KiB 넘음(경고)", lambda f: append(f / "AGENTS.md", "<!-- " + "가" * 4300 + " -->\n"), 0, "! AGENTS.md"),
    ("문서: AGENTS.md 16KiB 넘음", lambda f: append(f / "AGENTS.md", "<!-- " + "가" * 5600 + " -->\n"), 1, "바이트입니다"),
]


def case_docs(edit, expected, text):
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        docs_repo(folder)
        edit(folder)
        result = subprocess.run([sys.executable, str(CHECK_DOCS), "--root", str(folder)], capture_output=True,
                                text=True, timeout=60)
        assert result.returncode == expected, f"종료 코드 {result.returncode}(기대 {expected}): {result.stdout}"
        if text:
            assert text in result.stdout, f"출력에 {text!r} 없음: {result.stdout}"
        elif expected == 0:
            assert not result.stdout.strip(), f"통과는 조용해야 함: {result.stdout}"


def case_docs_real():
    started = time.monotonic()
    result = subprocess.run([sys.executable, str(CHECK_DOCS)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, "이 저장소 문서 검사 실패:\n" + result.stdout
    assert time.monotonic() - started < 10, "문서 검사가 10초를 넘음"


# check-prose.py 규칙 경우: (이름, 문서 글, 있어야 할 규칙, 없어야 할 규칙). 오탐 표본(연구 §4.5)을 함께 둔다
def words(count, tail="다."):
    return " ".join(["낱말"] * (count - 1) + ["낱말" + tail])


PROSE_RULES = [
    ("E1: 26어절", f"- {words(26)}\n", {"E1"}, {"W1"}),
    ("E1 아님: 25어절은 경고만", f"- {words(25)}\n", {"W1"}, {"E1"}),
    ("W1: 설명 18어절", f"{words(18)}\n", {"W1"}, {"E1"}),
    ("W1 아님: 설명 17어절", f"- {words(17)}\n", set(), {"W1"}),
    ("W1: 절차(번호 목록) 15어절", f"1. {words(15)}\n", {"W1"}, set()),
    ("W1 아님: 절차 14어절", f"1. {words(14)}\n", set(), {"W1"}),
    ("E2: 가운뎃점 3개(4항목)", "- 큐·그리드·게인·태그를 쓴다.\n", {"E2"}, set()),
    ("E2 아님: 3항목", "- 큐·그리드·게인을 쓴다.\n", set(), {"E2"}),
    ("E2 아님: 코드 안 가운뎃점", "- `a·b·c·d`를 쓴다.\n", set(), {"E2"}),
    ("E3: 괄호 두 묶음", "- 반영(쓰기)은 관문(입구)을 지난다.\n", {"E3"}, set()),
    ("E3: 괄호 안 4어절", "- 반영(쓰기 전에 백업을 남긴다)을 한다.\n", {"E3"}, set()),
    ("E3 아님: 이슈 번호·식별자 하나는 참조", "- 관문(`RekordboxWriteGuard`)이 막는다(#182).\n", set(), {"E3"}),
    ("E3 아님: 예 3어절", "- 짧게 쓴다(예: 곡 두 개). 하나만 쓴다(설명).\n", set(), {"E3"}),
    ("E3 아님: 링크 주소 괄호", "- [안내](docs/a.md)와 [규칙](docs/b.md)을 본다.\n", set(), {"E3"}),
    ("E3 아님: 코드·URL 안 괄호", "- `f(a)`와 `g(b)`, https://x.y/a(b) 를 본다.\n", set(), {"E3"}),
    ("E4: 이중 피동", "- 값이 잡혀진다.\n", {"E4"}, set()),
    ("E4: 되어지다", "- 파일이 저장되어진다.\n", {"E4"}, set()),
    ("E4: -되어야 한다", "- 백업이 먼저 되어야 한다.\n", {"E4"}, set()),
    ("E4 아님: 옮겨지다·알려진", "- 파일을 옮긴다. 알려진 한계다.\n", set(), {"E4"}),
    ("E5: 쓰지 않는 말", "- 플레이리스트를 고른다.\n", {"E5"}, set()),
    ("E5: 띄어 쓴 쓰지 않는 말", "- 전체 테스트를 돌린다.\n", {"E5"}, set()),
    ("E5 아님: 따옴표 안 화면 이름", '- rekordbox의 "장치와 플레이리스트 동기화"를 끈다.\n', set(), {"E5"}),
    ("E5 아님: 코드 안", "- `플레이리스트`를 찾는다. 자가 테스트를 돌린다.\n", set(), {"E5"}),
    ("E6: 문단 7문장", "가다. " * 7 + "\n", {"E6"}, set()),
    ("E6 아님: 문단 6문장", "가다. " * 6 + "\n", set(), {"E6"}),
    ("W2: -고", "- 빌드하고 시험한다.\n", {"W2"}, set()),
    ("W2: -지만", "- 빠르지만 정확하지 않다.\n", {"W2"}, set()),
    ("W2 아님: 경고·보고·참고", "- 경고·보고를 남긴다. 참고 문서를 본다.\n", set(), {"W2"}),
    ("W2 아님: -고 있다", "- 시험을 돌리고 있다.\n", set(), {"W2"}),
    ("W2 아님: 인용 -다고", "- 통과했다고 적는다.\n", set(), {"W2"}),
    ("W2 아님: 괄호 안", "- 시험을 돌린다(빌드하고 나서).\n", set(), {"W2"}),
    ("W4: 명사+되다", "- 초안은 파일로 저장된다.\n", {"W4"}, set()),
    ("W4: -어지다", "- 목록이 만들어진다.\n", {"W4"}, set()),
    ("W4 아님: 바뀌다·보이다·막히다", "- 값이 바뀐다. 경고가 보인다. 쓰기가 막힌다.\n", set(), {"W4", "E4"}),
    ("W3: 형태소 분석기 없으면 판정 안 함", "- 쓰기 관문 반영 세션 시험 재료 목록을 본다.\n", set(), {"W3"}),
    ("표 칸: 길이만 본다", "| 칸 | 칸 |\n|---|---|\n| 반영(쓰기)은 관문(입구)을 지나고 | 큐·그리드·게인·태그 |\n",
     set(), {"E2", "E3", "W2"}),
    ("표 칸: 26어절은 E1", f"| 칸 |\n|---|\n| {words(26)} |\n", {"E1"}, set()),
    ("영어 문장: 낱말 수만", "- This (a) (b) uses a·b·c·d and runs.\n", set(), {"E2", "E3"}),
    ("영어 문장: 26낱말은 E1", "- " + " ".join(["word"] * 26) + ".\n", {"E1"}, set()),
    ("뺌: 코드 블록·제목·머리·HTML 주석", "---\nname: x\n---\n# 플레이리스트(a)(b)\n\n```\n플레이리스트\n```\n\n<!-- 플레이리스트 -->\n",
     set(), {"E5", "E3"}),
    ("예외: 줄 끝 표시", "- 반영(쓰기)은 관문(입구)을 지난다. <!-- prose: E3 -->\n", set(), {"E3"}),
    ("예외: 줄 끝 표시는 그 규칙만", "- 반영(쓰기)은 관문(입구)을 지나고 끝난다. <!-- prose: E3 -->\n", {"W2"}, {"E3"}),
    ("예외 아님: 인라인 코드 안의 표시 예시", "- 반영(쓰기)은 관문(입구)을 `<!-- prose: E3 -->`로 뺀다.\n", {"E3"}, set()),
    ("예외: 파일 머리 off", "<!-- prose: off -->\n\n- 플레이리스트(a)(b)를 고른다.\n", set(), {"E5", "E3"}),
]


def load_prose():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("check_prose", CHECK_PROSE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def case_prose_rule(text, present, absent):
    prose = load_prose()
    found = {rule for unit in prose.analyze(text, "a.md", prose.load_terms(ROOT / "scripts/prose-terms.txt")).units
             for rule in unit.rules}
    assert present <= found, f"걸려야 할 규칙 {sorted(present - found)}이 없음(찾은 것 {sorted(found)})"
    assert not (absent & found), f"걸리면 안 되는 규칙 {sorted(absent & found)}(찾은 것 {sorted(found)})"


def case_prose_morph():
    """명사 묶음(W3)은 kiwipiepy가 있을 때만 --morph로 본다. 없으면 판정 안 함을 알리고 점수에서 뺀다."""
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        prose_repo(folder, {"AGENTS.md": "- 쓰기 관문 반영 세션 시험 재료 목록 경로를 본다.\n- 확인 창 대신 경고 알림을 띄운다.\n",
                            "scripts/prose-baseline.txt": "AGENTS.md\tA=0.0\tB=100.0\n"})
        result = run_prose(folder, "--all", "--no-diff", "--morph")
        if importlib.util.find_spec("kiwipiepy") is None:
            assert "kiwipiepy가 없어" in result.stdout and ": W3" not in result.stdout, result.stdout
        else:
            assert "AGENTS.md:1: W3" in result.stdout and "AGENTS.md:2: W3" not in result.stdout, result.stdout


def case_prose_split():
    """숫자 7.2.18·약어 점에서 나누지 않고, 괄호 밖 `. ` 뒤에서만 나눈다. 줄 번호는 문장이 시작한 줄이다."""
    prose = load_prose()
    doc = prose.analyze("# 제목\n\n- rekordbox 7.2.18에서 확인했다(v1. 2). 다음을\n  본다. `a. b`를 쓴다.\n", "a.md")
    sentences = [u for u in doc.units if u.kind == "sentence"]
    assert [u.line for u in sentences] == [3, 3, 4], [(u.line, u.text) for u in sentences]
    assert sentences[1].lines == {3, 4}, sentences[1].lines
    # 굵게·따옴표로 닫은 문장 끝(`**첫 문장.** 다음`)에서도 나눈다
    bold = prose.analyze('- **굵은 첫 문장.** 다음 문장. "인용 끝." 그다음.\n', "a.md")
    assert [u.text for u in bold.units] == ["굵은 첫 문장.", "다음 문장.", '"인용 끝."', "그다음."], [u.text for u in bold.units]


def case_prose_metrics():
    """A = 위반 0인 문장 ÷ 문장, A' = 오류 0인 문장 ÷ 문장, B = 위반 ÷ 어절 × 100, B' = 오류 ÷ 어절 × 100."""
    prose = load_prose()
    doc = prose.analyze("- 곡을 고른다.\n- 빌드하고 시험한다.\n- 플레이리스트를 고른다.\n- 시험을 돌린다.\n", "a.md",
                        prose.load_terms(ROOT / "scripts/prose-terms.txt"))
    m = doc.metrics()
    assert (m["sentences"], m["words"]) == (4, 8), m
    assert (round(m["A"], 1), round(m["A2"], 1)) == (50.0, 75.0), m
    assert (round(m["B"], 1), round(m["B2"], 1)) == (25.0, 12.5), m
    total = prose.combine([m, prose.analyze("- 곡을 고른다. 곡을 고른다.\n", "b.md").metrics()])
    assert (total["sentences"], round(total["A"], 1), round(total["B"], 1)) == (6, 66.7, 16.7), total


def prose_repo(folder, files):
    git(folder, "init", "-q", "-b", "main")
    git(folder, "config", "user.email", "t@example.com")
    git(folder, "config", "user.name", "t")
    (folder / "scripts").mkdir()
    shutil.copy(ROOT / "scripts/prose-terms.txt", folder / "scripts/prose-terms.txt")
    for name, text in files.items():
        (folder / name).parent.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(text)
    git(folder, "add", "-A")
    git(folder, "commit", "-q", "-m", "a")


def run_prose(folder, *arguments):
    return subprocess.run([sys.executable, str(CHECK_PROSE), "--root", str(folder), *arguments], capture_output=True,
                          text=True, timeout=60)


GOOD = "- 곡을 고른다.\n- 시험을 돌린다.\n"
BAD = "- 곡을 고른다.\n- 빌드하고 시험한다.\n"


def case_prose_cli(files, baseline, edit, arguments, expected, texts, after=None):
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        prose_repo(folder, {**files, "scripts/prose-baseline.txt": baseline})
        edit(folder)
        if "TREE" in arguments:
            arguments = [(folder / "tree.txt").read_text() if a == "TREE" else a for a in arguments]
        result = run_prose(folder, *arguments)
        output = result.stdout + result.stderr
        assert result.returncode == expected, f"종료 코드 {result.returncode}(기대 {expected}): {output}"
        for text in texts:
            assert text in output, f"출력에 {text!r} 없음: {output}"
        if after:
            after(folder, output)


def baseline_has(line):
    def check(folder, output):
        body = (folder / "scripts/prose-baseline.txt").read_text()
        assert line in body, f"기준선에 {line!r} 없음: {body}"
    return check


def nothing(folder):
    pass


def untracked_in_base(folder):
    """기준 트리(추적 안 된 파일까지 담은 것)에 이미 있던 문서: 오류가 있던 옛 줄은 보지 않고 바꾼 줄만 본다."""
    (folder / "docs").mkdir()
    (folder / "docs/old.md").write_text("- 에러를 본다.\n")
    git(folder, "add", "docs/old.md")
    tree = subprocess.run(["git", "-C", str(folder), "write-tree"], check=True, capture_output=True, text=True,
                          timeout=20).stdout.strip()
    git(folder, "rm", "-q", "--cached", "docs/old.md")
    append(folder / "docs/old.md", "- 빌드하고 시험한다.\n")
    (folder / "tree.txt").write_text(tree)


def prefixed_diff(folder):
    """diff 접두사를 바꾸는 사용자 설정과 `++`로 시작하는 본문 줄이 더한 줄 해석을 흐리지 않는다."""
    git(folder, "config", "diff.mnemonicPrefix", "true")
    git(folder, "config", "diff.noprefix", "true")
    append(folder / "AGENTS.md", "- 플레이리스트를 고른다.\n++ 에러.\n- 디렉터리를 연다.\n")


def assert_absent(folder, name):
    body = (folder / "scripts/prose-baseline.txt").read_text()
    assert name not in body, f"기준선에 {name}을 적음: {body}"


PROSE_CLI = [
    ("prose: 기준선 그대로면 한 줄", {"AGENTS.md": BAD}, "AGENTS.md\tA=50.0\tB=25.0\n", nothing, ["--base", "HEAD"], 0,
     ["✔ check-prose"]),
    ("prose: A가 내려가면 실패", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\n",
     lambda f: (f / "AGENTS.md").write_text(BAD), ["--no-diff"], 1, ["✘ AGENTS.md: 기준선", "A 50.0 < 80.0", "| AGENTS.md"]),
    ("prose: B가 올라가면 실패", {"AGENTS.md": BAD}, "AGENTS.md\tA=50.0\tB=20.0\n", nothing, ["--no-diff"], 1,
     ["B 25.0 > 20.0"]),
    ("prose: 좋아지면 기준선을 고치라고 알린다", {"AGENTS.md": BAD}, "AGENTS.md\tA=50.0\tB=25.0\n",
     lambda f: (f / "AGENTS.md").write_text(GOOD), ["--no-diff"], 0, ["--write-baseline"]),
    ("prose: --write-baseline은 좋아진 값을 적고 80% 넘으면 80으로", {"AGENTS.md": BAD}, "AGENTS.md\tA=50.0\tB=25.0\n",
     lambda f: (f / "AGENTS.md").write_text(GOOD), ["--no-diff", "--write-baseline"], 0, [],
     baseline_has("AGENTS.md\tA=80.0\tB=0.0")),
    ("prose: --write-baseline은 나빠진 값을 적지 않는다", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\n",
     lambda f: (f / "AGENTS.md").write_text(BAD), ["--no-diff", "--write-baseline"], 1, ["A 50.0 < 80.0"],
     baseline_has("AGENTS.md\tA=80.0\tB=0.0")),
    ("prose: 기준선에 없는 새 문서는 80% 아래면 실패", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\n",
     lambda f: (f / "docs").mkdir() or (f / "docs/new.md").write_text(BAD), ["--no-diff"], 1, ["docs/new.md: 기준선에 없음"]),
    ("prose: 더한 줄의 오류는 실패", {"AGENTS.md": GOOD}, "AGENTS.md\tA=0.0\tB=100.0\n",
     lambda f: append(f / "AGENTS.md", "- 플레이리스트를 고른다.\n"), ["--base", "HEAD"], 1,
     ['✘ AGENTS.md:3: E5 쓰지 않는 말 — "플레이리스트를 고른다.']),
    ("prose: 더한 줄의 경고는 줄만 보인다", {"AGENTS.md": GOOD}, "AGENTS.md\tA=0.0\tB=100.0\n",
     lambda f: append(f / "AGENTS.md", "- 빌드하고 시험한다.\n"), ["--base", "HEAD"], 0, ["! AGENTS.md:3: W2"]),
    ("prose: 고친 줄에 걸친 여러 줄 문장도 본다", {"AGENTS.md": "- 곡을\n  플레이리스트에 넣는다.\n"}, "AGENTS.md\tA=0.0\tB=100.0\n",
     lambda f: (f / "AGENTS.md").write_text("- 곡을 꼭\n  플레이리스트에 넣는다.\n"), ["--base", "HEAD"], 1, ["✘ AGENTS.md:1: E5"]),
    ("prose: 고치지 않은 줄의 오류는 기준선 몫", {"AGENTS.md": "- 플레이리스트를 고른다.\n"}, "AGENTS.md\tA=0.0\tB=100.0\n",
     lambda f: append(f / "AGENTS.md", "\n- 곡을 고른다.\n"), ["--base", "HEAD"], 0, ["✔ check-prose"]),
    ("prose: 추적 안 된 새 문서는 줄 전체가 더한 줄", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\ndocs/new.md\tA=0.0\tB=100.0\n",
     lambda f: (f / "docs").mkdir() or (f / "docs/new.md").write_text("- 에러를 본다.\n"), ["--base", "HEAD"], 1,
     ["✘ docs/new.md:1: E5"]),
    ("prose: 기준 트리에 있던 추적 안 된 문서는 바뀐 줄만", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\ndocs/old.md\tA=0.0\tB=100.0\n",
     untracked_in_base, ["--base", "TREE"], 0, ["✔ check-prose", "경고 1"]),
    ("prose: diff 접두사 설정과 무관", {"AGENTS.md": GOOD}, "AGENTS.md\tA=0.0\tB=100.0\n",
     prefixed_diff, ["--base", "HEAD"], 1,
     ["✘ AGENTS.md:3: E5", "✘ AGENTS.md:5: E5"]),
    ("prose: --write-baseline은 80% 아래 새 문서를 적지 않는다", {"AGENTS.md": GOOD}, "AGENTS.md\tA=80.0\tB=0.0\n",
     lambda f: (f / "docs").mkdir() or (f / "docs/new.md").write_text(BAD), ["--no-diff", "--write-baseline"], 1,
     ["docs/new.md: 기준선에 없음"], lambda f, o: assert_absent(f, "docs/new.md")),
    ("prose: 줄 예외 표시는 diff 규칙에도", {"AGENTS.md": GOOD}, "AGENTS.md\tA=0.0\tB=100.0\n",
     lambda f: append(f / "AGENTS.md", "- 플레이리스트를 고른다. <!-- prose: E5 -->\n"), ["--base", "HEAD"], 0,
     ["예외 1"]),
    ("prose: --report는 실패 없이 표만", {"AGENTS.md": BAD}, "AGENTS.md\tA=80.0\tB=0.0\n", nothing, ["--report"], 0,
     ["| AGENTS.md | 2 |", "| **전체** |"]),
    ("prose: --files로 대상 지정", {"AGENTS.md": GOOD, "docs/a.md": BAD}, "AGENTS.md\tA=80.0\tB=0.0\n", nothing,
     ["--report", "--files", "docs/a.md"], 0, ["| docs/a.md |"]),
    ("prose: --all은 모든 위반 줄", {"AGENTS.md": BAD}, "AGENTS.md\tA=50.0\tB=25.0\n", nothing,
     ["--all", "--no-diff"], 0, ["! AGENTS.md:2: W2 대등 연결"]),
    ("prose: 인자 오류는 2", {"AGENTS.md": GOOD}, "", nothing, ["--nope"], 2, []),
    ("prose: 없는 기준은 2", {"AGENTS.md": GOOD}, "", nothing, ["--base", "no-such-rev"], 2, ["기준"]),
]


def case_prose_preserve():
    """고쳐 쓴 전후의 숫자·식별자·이슈 번호·부정어를 비교해 빠진 것을 나열한다."""
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        old, new = folder / "old.md", folder / "new.md"
        old.write_text("- rekordbox 7.2.18에서 `RekordboxWriter.write`만 쓴다(#182). USB에 쓰지 않는다. 25어절.\n")
        new.write_text("- rekordbox에서 쓰기 입구만 쓴다. USB에 쓴다. 25어절.\n")
        result = subprocess.run([sys.executable, str(CHECK_PROSE), "--preserve", str(old), "--to", str(new)],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 1, result.stdout + result.stderr
        for text in ("7.2.18", "RekordboxWriter.write", "#182", "부정어"):
            assert text in result.stdout, f"빠진 것 {text!r}을 알리지 않음: {result.stdout}"
        assert "25" not in result.stdout.replace("25어절", ""), f"남은 숫자까지 알림: {result.stdout}"
        same = subprocess.run([sys.executable, str(CHECK_PROSE), "--preserve", str(old), "--to", str(old)],
                              capture_output=True, text=True, timeout=30)
        assert same.returncode == 0, same.stdout


def case_prose_real():
    """이 저장소: 기준선을 지키고 1초 안팎에 끝난다(diff 규칙은 브랜치마다 달라 --changed·전체 검사가 본다)."""
    started = time.monotonic()
    result = subprocess.run([sys.executable, str(CHECK_PROSE), "--no-diff"], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, "이 저장소 문장 검사 실패:\n" + result.stdout[-3000:]
    assert time.monotonic() - started < 5, "문장 검사가 5초를 넘음"


def case_worker_lock():
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        git(repo, "init", "-q")
        (repo / "sub").mkdir()

        def lock(*arguments, cwd=repo):
            return subprocess.run(["bash", str(WORKER_LOCK), *arguments], capture_output=True, text=True, timeout=10, cwd=cwd)

        marker = repo / ".djc-worker.lock"
        assert lock("show").returncode == 1, "표시가 없으면 show는 1"
        assert lock("take").returncode == 2, "작업 이름 없는 take는 2"
        first = lock("take", "작업 가", "세션1", cwd=repo / "sub")
        assert first.returncode == 0 and marker.exists(), f"하위 폴더에서도 뿌리에 만든다: {first.stderr}"
        text = marker.read_text()
        assert "작업: 작업 가" in text and "세션: 세션1" in text and "시각: " in text, text
        second = lock("take", "작업 나")
        assert second.returncode == 1 and "작업 가" in second.stderr, "이미 있으면 멈추고 앞 작업을 보인다"
        assert marker.read_text() == text, "앞 표시를 덮지 않는다"
        other = lock("drop", "작업 나")
        assert other.returncode == 1 and marker.exists(), "다른 작업의 표시는 지우지 않는다"
        assert lock("show").returncode == 0
        assert lock("drop", "작업 가").returncode == 0 and not marker.exists()
        assert lock("drop", "작업 가").returncode == 0, "이미 없으면 조용히 끝난다"


CASES = [(f"막음: {c!r}", case_guard, (c, 2)) for c in BLOCK]
CASES += [(f"통과: {c!r}", case_guard, (c, 0)) for c in ALLOW]
CASES += [(f"cwd {cwd}: {c!r}", case_guard, (c, expected, cwd)) for cwd, c, expected in CWD_CASES]
CASES += [(f"알려진 한계(통과): {c!r}", case_guard, (c, 0)) for c in LIMITS]
CASES += [(f"Stop: {name}", case_stop, rest) for name, *rest in STOP_CASES]
CASES += [
    ("PreToolUse: Bash 밖 도구·깨진 입력은 통과", case_guard_other_tool, ()),
    ("PostToolUse: 경계 통과는 조용히", case_imports, (0, "Sources/DJCDomain/A.swift", 0)),
    ("PostToolUse: 경계 위반은 위반 줄만 종료 2", case_imports, (1, "Sources/DJCDomain/A.swift", 2, "✘ 새 위반")),
    ("PostToolUse: Package.swift도 본다", case_imports, (1, "Package.swift", 2, "✘ 새 위반")),
    ("PostToolUse: 문서는 보지 않는다", case_imports, (1, "docs/a.md", 0)),
    ("PostToolUse: 저장소 밖 파일은 보지 않는다", case_imports, (1, "../outside.swift", 0)),
    ("PostToolUse: 이 저장소 실제 검사", case_imports_real, ()),
    ("PostToolUse: 타깃 밖으로 옮긴 Swift 파일을 알린다", case_imports_moved, ()),
    ("Stop: 저장소 밖 → 조용히", case_stop_outside_repo, ()),
    ("SessionStart: 안전 절만 싣는다", case_session, (True,)),
    ("SessionStart: 절이 없으면 조용히", case_session, (False,)),
    ("SessionStart: 이 저장소 AGENTS.md", case_session_real, ()),
    ("settings.json: 훅·권한 모양", case_settings, ()),
    ("settings.json: 훅 명령을 sh로 그대로(스크립트 없으면 조용히)", case_settings_commands_run, ()),
    ("PreToolUse: 훅의 djc 명령 이름이 소스 등록과 맞음", case_guard_names, ()),
    ("워크트리 작업 표시: 만들기·겹침 거부·남의 표시 지키기", case_worker_lock, ()),
]
CASES += [(name, case_docs, (edit, expected, text)) for name, edit, expected, text in DOCS_CASES]
CASES += [("문서: 이 저장소 검사", case_docs_real, ())]
CASES += [(f"문장 규칙 {name}", case_prose_rule, (text, present, absent)) for name, text, present, absent in PROSE_RULES]
CASES += [("문장 규칙 W3: 형태소 분석(--morph)", case_prose_morph, ()), ("문장 나누기: 숫자·괄호·여러 줄", case_prose_split, ()), ("문장 지표: A·A'·B·B'·가중 전체", case_prose_metrics, ())]
CASES += [(name, case_prose_cli, rest) for name, *rest in PROSE_CLI]
CASES += [("prose: 정보 보존(--preserve)", case_prose_preserve, ()), ("prose: 이 저장소 검사", case_prose_real, ())]


def main(arguments):
    quiet = arguments == ["--quiet"]
    if arguments and not quiet:
        print("사용: python3 scripts/test-harness.py [--quiet]")
        return 2
    failures = 0
    for name, function, case_arguments in CASES:
        try:
            function(*case_arguments)
            if not quiet:
                print(f"✔ {name}")
        except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            failures += 1
            print(f"✘ {name}: {error}")
    print(f"하네스 시험: {len(CASES)}개 중 {len(CASES) - failures}개 통과")
    return 1 if failures else 0


if __name__ == "__main__":
    shutil.which("git") or sys.exit("git이 필요합니다")
    sys.exit(main(sys.argv[1:]))
