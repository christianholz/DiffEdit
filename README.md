# DiffEdit

A macOS text editor built around reviewing and refining changes against Git.
Edit your working text alongside its last committed version, with differences
and corresponding passages kept in view as you write.

## Features

- **Live word-level diffs.** Additions and deletions are highlighted within
  sentences as you edit.
- **Past and present in context.** Cursor movement and text selections highlight
  the corresponding original passages, including text that was replaced or
  deleted. Synchronized views follow long, wrapped paragraphs.
- **Selective restoration.** Restore individual phrases or selected changes,
  with undo and redo support.
- **Selective Git commits.** Commit chosen files or individual added and deleted
  lines—including edits from unsaved buffers—while preserving the rest of your
  work for later.

## Implementation

DiffEdit uses **Tauri** for its macOS application shell, **CodeMirror** for editing,
and **Rust** for diff computation, file operations, and Git integration.
The editor and interface live in `frontend/`; native application code lives in
`backend/`; development checks live in `scripts/`.

Typing updates the editor and provisional highlights immediately. Edits are sent
to Rust as they occur; versioned responses keep the final diff
in sync with the current text. The diff engine combines line alignment with token
and character refinement to retain useful context within changed paragraphs.
File and Git operations run on background workers.

## Build and run

Requirements: macOS 13 or newer, Xcode command-line tools, Rust stable, Git, and
Node.js 22.12 or newer. Dependency versions are pinned in the npm and Cargo lockfiles.

From the repository root:

```sh
npm ci
npm run tauri -- dev
```

For an optimized application:

```sh
npm run build:app
open 'backend/target/release/bundle/macos/DiffEdit.app'
```
