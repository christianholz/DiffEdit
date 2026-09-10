# DiffEdit

DiffEdit is a native macOS text editor built around one idea: source changes are
easier to understand when the code you are writing and the code you started
from stay visible together.

Open a folder inside a Git repository and DiffEdit compares every edited file
with `HEAD` as you type. It highlights line- and word-level changes, keeps the
relevant committed context above the editor, and lets you review, stage, and
commit selected lines without leaving the app.

> DiffEdit is currently an early-stage project for macOS 13 and newer.

## Highlights

- **Git-aware editing** — additions, edits, and deletions are highlighted
  against the version in `HEAD`, with line numbers, deletion markers, and a
  document overview showing where changes are located.
- **Committed context at the caret** — a resizable pane follows the current
  editing position and shows the corresponding committed lines, making small
  changes easy to understand without switching to a separate diff view.
- **Focused change navigation** — jump between changed blocks and continue
  across changed files from the keyboard.
- **Selective staging** — review a compact unified diff, include or exclude
  individual added and deleted lines, and stage directly from the in-memory
  editor buffer. A file does not need to be saved before it is staged.
- **Built-in commits** — write a summary and optional description, then commit
  the selected changes to the current branch from within DiffEdit.
- **Multi-file buffers** — move between files without losing edits. DiffEdit
  marks unsaved buffers and offers to save them together when a window closes.
- **Safe external-change handling** — if another process changes or deletes an
  open file, DiffEdit asks whether to keep the buffer, reload from disk, or
  cancel before overwriting anything.
- **Quick file access** — browse the repository tree, filter files with Quick
  Open, reopen recent folders, and work in multiple folder windows.
- **Native macOS experience** — an AppKit interface with standard menus,
  keyboard shortcuts, adjustable type size, and optional word wrapping.

## Typical workflow

1. Open a folder within a Git repository.
2. Select a file from the sidebar or press <kbd>⌘T</kbd> to use Quick Open.
3. Edit while the committed-context pane and inline highlights track the
   difference from `HEAD`.
4. Switch from **Edit** to **Stage & Commit**.
5. Choose the lines to include, stage them, and create the commit.

DiffEdit also works when the opened folder is below the repository root. To
avoid committing changes you cannot see, it blocks commits if the Git index
contains staged files outside the opened folder.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Quick Open | <kbd>⌘T</kbd> |
| Save current file | <kbd>⌘S</kbd> |
| Find / replace | <kbd>⌘F</kbd> / <kbd>⌥⌘F</kbd> |
| Next / previous match | <kbd>⌘G</kbd> / <kbd>⇧⌘G</kbd> |
| Previous / next change | <kbd>⇧⌘,</kbd> / <kbd>⇧⌘.</kbd> |
| Previous / next paragraph | <kbd>⌥↑</kbd> / <kbd>⌥↓</kbd> |
| Toggle word wrapping | <kbd>⌥⌘W</kbd> |
| Increase / decrease type size | <kbd>⌘+</kbd> / <kbd>⌘−</kbd> |

Search operates on the current editable document, using case-insensitive literal
matching and wrapping at the ends. Return and Shift-Return navigate from the
search field; Escape closes the bar. Replace and Replace All update the buffer
and support Undo; save the file to write replacements to disk.

## Build and run

### Xcode

Requirements:

- macOS 13 or newer
- Xcode 15 or newer

Open `DiffEdit.xcodeproj`, select the shared **DiffEdit** scheme, and press
<kbd>⌘R</kbd>.

The checked-in Xcode project is generated from `project.yml`. After changing
the project structure, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

### Command line

Build a runnable app bundle with:

```sh
./Scripts/build_app.sh
```

The resulting app is written to `build/DiffEdit.app`.

Run the test suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

## Project structure

DiffEdit has no third-party runtime dependencies. The app is written in Swift
and AppKit, with the main code organized around:

- `EditorViewController.swift` and `EditorViews.swift` — editing, committed
  context, navigation, and diff presentation
- `DiffEngine.swift` — line and word diffs plus selective-staging plans
- `Repository.swift` — repository discovery, status, staging, and commits
- `Sidebar.swift` and `QuickOpen.swift` — folder navigation and file access
- `StagingDiffView.swift` — unified-diff review and per-line selection

## License

DiffEdit is available under the [MIT License](LICENSE).

## Performance diagnostics

Set `DIFFEDIT_TIMINGS=1` in the Xcode scheme’s environment variables, or launch
`DIFFEDIT_TIMINGS=1 build/DiffEdit.app/Contents/MacOS/DiffEdit` from a terminal.
The console reports milliseconds for each Git command, file-tree construction,
initial sidebar rendering, total folder opening, and Quick Open enumeration.
Timings are disabled by default; folder opening includes background queue time.
