# DiffEdit

A macOS text editor for reviewing and editing Git changes.

## Features

- Live word-level diffs with synchronized Past and Now panes.
- Selective restoration of changes, with undo and redo.
- Staging and commits by file or line, including unsaved edits.
- Quick file search, change navigation, and bracket matching.

## Build and run

Requires macOS 14+, Xcode command-line tools, stable Rust, Git, and Node.js 22.12+.

From the repository root:

```sh
npm ci
npm run build:app
open backend/target/release/bundle/macos/DiffEdit.app
```

For development, run `npm run tauri -- dev`. With Xcode, open
`DiffEdit.xcodeproj`, select **DiffEdit → My Mac**, and press **⌘R**.
