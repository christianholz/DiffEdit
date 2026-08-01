# DiffEdit

DiffEdit is a native macOS text editor that keeps the current file beside a
small committed-context view and highlights working-tree changes against Git
`HEAD`.

## Build in Xcode

Open `DiffEdit.xcodeproj`, select the shared **DiffEdit** scheme, and press
Command-R. The project contains:

- the macOS application target;
- a `DiffEditTests` unit-test target;
- generated Info.plist settings and a macOS 13 deployment target.

The checked-in Xcode project is generated from `project.yml`. If the source
layout changes and XcodeGen is installed, regenerate it with:

```sh
xcodegen generate
```

## Source layout

- `Application.swift`: application lifecycle, menus, windows, and feature coordination
- `QuickOpen.swift`: quick-open panel and filtering
- `Sidebar.swift`: repository outline and file cells
- `EditorViewController.swift`: document editing workflow and diff presentation
- `EditorBuffer.swift`: per-file in-memory text and navigation state
- `EditorViews.swift`: reusable text, gutter, and change-overview views
- `StagingDiffView.swift`: native unified-diff review and per-line staging controls
- `EditorTheme.swift`: shared diff colors
- `Repository.swift`: filesystem tree and Git access
- `DiffEngine.swift`: diff result models and algorithms
- `TextUtilities.swift`: shared line and range helpers

## Command-line build

```sh
./Scripts/build_app.sh
```

This creates `build/DiffEdit.app`. The script selects the full Xcode toolchain
when it is installed, which avoids a compiler/SDK mismatch when
`xcode-select` currently points at standalone Command Line Tools.

Run the unit tests with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

## Editing and committing

DiffEdit keeps edits to multiple files buffered in memory when you move between
files. A light-gray dot in the file list marks a buffer that has not been saved
to disk. Closing a window with buffered edits offers to save all of them.

Use the **Edit** / **Stage & Commit** switch above the editor to enter source
control mode. Changed lines are selected by default and can be included or
excluded independently in the unified diff. Staging uses the in-memory buffer,
so saving the file first is not required. The commit form accepts a required
summary and an optional description.

Before overwriting a file that changed outside DiffEdit, the app asks whether
to keep the buffer, reload from disk, or cancel. Commits are blocked when the
Git index contains staged files that are outside the opened folder or otherwise
not represented in the file viewer. When a DiffEdit window becomes active, its
open file is reread and rediffed only if that file's modification date changed;
the caret returns to the same logical line and column after a reload.

## Useful shortcuts

- Command-T: quick-open a file
- Command-Shift-Comma: previous changed block
- Command-Shift-Period: next changed block
- Option-Up / Option-Down: move between paragraphs
- Option-Command-W: toggle word wrapping
