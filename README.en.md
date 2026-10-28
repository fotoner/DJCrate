# DJCrate

[![Build & Test](https://github.com/fotoner/DJCrate/actions/workflows/check.yml/badge.svg?branch=dev)](https://github.com/fotoner/DJCrate/actions/workflows/check.yml) [![License: GPL-2.0-or-later](https://img.shields.io/badge/license-GPL--2.0--or--later-blue.svg)](LICENSE)

[한국어](README.md) | **English** | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

> [!WARNING]
> DJCrate is still in **beta** (0.x), so you may run into unexpected problems.
>
> DJCrate automatically backs up your entire library before it writes to rekordbox. If something goes wrong after a write, roll it back with [Restore Before Write…] in the menu bar under rekordbox, or the same item in the Help menu. If the problem remains, please contact us through [Issues](https://github.com/fotoner/DJCrate/issues).
>
> DJCrate is provided "as is" under the [GPL-2.0-or-later license](LICENSE). The developer is not responsible for any data loss or damage that occurs while using it.

DJCrate is a macOS app for editing a rekordbox 7 library without launching rekordbox. It is a library management tool, not a performance app. It also ships with a command-line tool, `djc`. The app UI is available in Korean, English, and Japanese.

> [!NOTE]
> The documentation (`docs/…`), `djc` output, and GitHub issues are in Korean. The links below point to the Korean documents.

![DJCrate deck and track list (synthetic test data)](docs/images/readme/en/main.png)

## Safety principles

- Every edit is kept as a draft. DJCrate writes to rekordbox only when you click [Write to rekordbox]. The shortcut is ⇧⌘E.
- It never writes while rekordbox or rekordboxAgent is running.
- It writes only to a verified version (7.2.x) with a verified database layout.
- It backs up the entire library before writing, writes in a single transaction, and reads the result back to verify it.
- You can roll back with [Restore Before Write…].
- It performs only writes that have been verified, field by field, against the result of the same edit made in rekordbox itself. Everything else is blocked, and the app shows why.

![Pending rekordbox Writes list and the tag inspector. Orange marks show fields not yet written (synthetic test data)](docs/images/readme/en/write-pending.png)

## Install and run

Prebuilt app builds (beta, Apple Silicon) are on [GitHub Releases](https://github.com/fotoner/DJCrate/releases). Installation steps for the downloaded app are in the [release documentation](docs/releasing.md#설치).

The app checks for new versions and lets you know. It installs an update only after verifying its signature, and it waits while it is writing to rekordbox or a USB drive. Choose automatic checks and automatic installs in Settings › [Updates]. v0.1.0 does not have this feature, so install the next version manually once.

To build from source, you need:

- macOS 27 or later
- Swift 6.2 or later (Xcode)
- rekordbox 7.2.x (verified on 7.2.18)

```bash
git clone https://github.com/fotoner/DJCrate.git && cd DJCrate
scripts/build-app.sh --install        # /Applications/DJCrate.app
swift build -c release --product djc  # .build/release/djc
```

1. Click ⟳ [Sync with rekordbox] in the toolbar (⌘R) to take a copy (snapshot) of the library. rekordbox can stay open for this step.
2. Edit in the deck and the track list. Edited tracks get a pending-write mark and are collected under [Pending rekordbox Writes] in the sidebar.
3. Quit rekordbox and rekordboxAgent completely.
4. Click [Write to rekordbox]. DJCrate first does a trial write to a copy. If anything is blocked or left out, a confirmation dialog lists those items first. Otherwise, it writes right away.
5. To roll back, click [Restore Before Write] in the result notification.

Copies, drafts, and backups are stored in `~/Library/Application Support/DJCrate/`. They contain a cloud token, so do not share them.

## Features

| Area | Features |
|---|---|
| Library | Playlist tree, filters (no cues, no grid, missing files, and more), relocation candidates for missing files (read-only), duplicate merging, adding and removing tracks, synced iTunes playlists |
| Deck | 3-band waveform, CUE, hot cues and memory cues, sample-accurate loops, quantize, tempo and Master Tempo (key lock), metronome, Auto Gain, cue, grid, gain, and key suggestions |
| Editing | Cues, grid and BPM (including tracks with tempo changes), gain, tags, rating and track color, album art. A spreadsheet-style Tag Sheet. For unanalyzed tracks, DJCrate creates and attaches the analysis files |
| Track edit and Flip (experimental) | Render bar-based cut edits, or edits that capture hot cue jumps and loop playing, to WAV and add them to the library |
| Playlists | Create playlists and folders, rename, move, delete, add and remove tracks, reorder. ⌘-click or ⇧-click in the sidebar to delete or move several at once |
| History | Browse play history and turn a history into a playlist. Keeps the history that CDJs and XDJs leave on a USB drive, then adds it to rekordbox's history |
| XML | Linked XML for importing into rekordbox, full-library XML export (read-only), rekordbox XML import (preview the differences, then make drafts), Apple Music XML import |
| USB (experimental) | Read, export, edit, and sync OneLibrary and Device Library; add OneLibrary to older USB drives. A physical USB drive is written only after you confirm the write in the [Export to USB] sheet or a write confirmation dialog (backed up before writing, verified after) |
| Rollback | Restore Before Write, restore points (automatic once a day, compare with now, restore to that point), fixing blocked drafts |
| Updates | Finds new versions on GitHub Releases, verifies the signature, then installs. Settings › [Updates] |
| Labs | Show intelligent playlists (read-only). Turn it on in Settings › [Labs] |
| CLI and agents | Use `djc` to browse the library and make cue, tag, and playlist drafts. It also has XML, USB, and restore point commands. Install and update the [skill](skills/djcrate/SKILL.md) for Claude Code and Codex, along with `djc`, in Settings › [AI Agents] |

![Tag Sheet and playlist tree (synthetic test data)](docs/images/readme/en/tag-sheet.png)

## Documentation

| Document | Contents |
|---|---|
| [docs/features.md](docs/features.md) | Features in detail, limitations, XML workflow, keyboard shortcuts |
| [docs/cli.md](docs/cli.md) | `djc` commands and JSON |
| [docs/rekordbox-internals.md](docs/rekordbox-internals.md) | rekordbox write rules confirmed by experiment |
| [docs/usb-internals.md](docs/usb-internals.md) | USB formats and write rules |
| [docs/architecture.md](docs/architecture.md) | Architecture and design decisions |
| [CONTRIBUTING.md](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) · [docs/issues.md](docs/issues.md) | Building and verification, working rules, [GitHub issue](https://github.com/fotoner/DJCrate/issues) rules |

## License

- Licensed under [GPL-2.0-or-later](LICENSE): the GNU General Public License, version 2, or (at your option) any later version. Copyright (c) 2026 Hyeonjae Nam.
- DJCrate moved from MIT to GPL-2.0-or-later to use [DJLinkKit](https://github.com/ImBada/DJLinkKit) (GPL-2.0-or-later) for Pro DJ Link features. Releases up to `v0.3.0` were published under MIT, and those copies keep their MIT terms.
- Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- rekordbox is a trademark of AlphaTheta. This app is an independent project not affiliated with AlphaTheta.
- The rekordbox database key is decrypted the same way as [pyrekordbox](https://github.com/dylanljones/pyrekordbox) (MIT).
