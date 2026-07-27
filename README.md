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

## Useful shortcuts

- Command-T: quick-open a file
- Option-Up / Option-Down: move between paragraphs
- Control-Comma / Control-Period: previous/next changed group
- Control-Shift-Comma / Control-Shift-Period: previous/next changed line
- Option-Command-W: toggle word wrapping
