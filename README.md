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
File and Git operations run on background workers. Document edits have one writer
per buffer; an interrupted acknowledgement recovers from a complete snapshot.
Diff results and staging selections identify both the buffer version and HEAD.

In Committing mode, checkboxes start from the existing Git index. The version
selector lets you review buffer changes or the staged version when they differ.
Stage selected lines updates the active file's index entry. Commit selected
changes applies pending checkbox selections and existing staged files, including
selected unsaved edits. Unrelated unchecked working files are not opened or
included. Editing after making a pending selection resets it and requires review.

Index updates use a locked temporary copy. Validation and ordinary hook failures
leave the original index intact. A completed commit is reported separately from
index installation or refresh failures; an installation failure preserves the
candidate index and reports its recovery path. Ambiguous Git outcomes also retain
the candidate for inspection. Refresh (Command-R) retries repository and document
inspection, continuing through individual file failures. HEAD, index, or baseline
changes invalidate pending selections.

Git baselines and staged text use Git's checkout filters, including CRLF attributes;
staging applies Git's clean filters. Ordinary folders compare against disk and
include dotfiles. Symbolic links, merge conflicts, binary files, and permission
changes are rejected by text staging; handle those with Git before reviewing text.

The reusable clean document cache is limited by count and size. Unsaved buffers,
pending selections, and documents with undo history are retained. Preferences
synchronize across windows, tolerate unavailable storage, and fit the viewport.

## Build and run

Requirements: macOS 13 or newer, Xcode command-line tools, Rust stable, Git, and
Node.js 22.12 or newer. Dependency versions are pinned in the npm and Cargo lockfiles.

From the repository root:

```sh
npm ci
npm run tauri -- dev
```

To launch from Xcode, open `DiffEdit.xcodeproj`, select the **DiffEdit** scheme
and **My Mac**, then press **Command-R**. The shared scheme builds the frontend
and Rust app through Tauri, then launches the resulting application in Xcode.
No Vite server or signing team is required. Rust artifacts go into Xcode's
DerivedData, including a backend source copy for Tauri's generated schemas; the
first build can take several minutes. Use the scheme's Release
configuration for an optimized build. Install dependencies with `npm ci` first.

For an optimized application:

```sh
npm run build:app
open 'backend/target/release/bundle/macos/DiffEdit.app'
```

## Development checks

```sh
npm run build
npm test
npm run test:editor
npm run test:native
npm run test:layout
cargo clippy --manifest-path backend/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path backend/Cargo.toml -- --check
```

The editor workflow checks exercise UI state with mocked Tauri IPC. Native tests
use real temporary Git repositories for staging, commits, filters, and recovery.
The macOS WebKit check verifies renderer layout under the application CSP. These
checks do not yet launch the packaged Tauri app through a complete automated user
workflow.
