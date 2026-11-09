import { virtualRows, clearVirtualRows } from "./virtual-rows";
import { DialogQueue } from "./dialogs";
import { BufferStore, DocumentSync } from "./synchronization";
import { readPreferences } from "./preferences";
import { pastViewport, wholeRowScroll } from "./past-viewport";
import { editorStyleNonce } from "./editor-style";
import { previewChanges } from "./preview";
import {
  EditorState,
  EditorSelection,
  StateEffect,
  StateField,
  Compartment,
  Transaction,
  Text,
} from "@codemirror/state";
import {
  EditorView,
  Decoration,
  DecorationSet,
  WidgetType,
  keymap,
  lineNumbers,
  highlightActiveLine,
  drawSelection,
} from "@codemirror/view";
import {
  history,
  historyKeymap,
  defaultKeymap,
  undo,
  redo,
  undoDepth,
  redoDepth,
  isolateHistory,
} from "@codemirror/commands";
import {
  search,
  SearchQuery,
  setSearchQuery,
  findNext,
  findPrevious,
  replaceNext,
  replaceAll,
  highlightSelectionMatches,
} from "@codemirror/search";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Menu, MenuItem } from "@tauri-apps/api/menu";

import { open } from "@tauri-apps/plugin-dialog";
import {
  Change,
  DiffUpdate,
  StageSnapshot,
  Repo,
  Document,
  StageRow,
  visible,
  changeAt,
  basePosition,
  wordRange,
} from "./model";
const $ = <T extends HTMLElement = HTMLElement>(s: string) =>
  document.querySelector<T>(s)!;

const win = getCurrentWindow();
let repo: Repo | null = null,
  active: BufferState | null = null,
  refreshing = false,
  closing = false;
const buffers = new BufferStore<BufferState>(),
  expanded = new Set<string>();
const prefs = readPreferences(localStorage);
let wrap: boolean = prefs.wrap ?? true,
  whitespace: boolean = prefs.whitespace ?? false,
  font: number = prefs.font ?? 13;
let pastHeight: number = Math.max(45, prefs.pastHeight ?? 5 * font * 1.55 + 16);
let quickPaths: string[] = [],
  quickIndex = 0,
  opening = 0;
interface BufferState extends Omit<Document, "text"> {
  state: EditorState;
  changes: Change[];
  sync: DocumentSync;
  index: string;
  locked: boolean;
  scroll: number;
  selection: Set<string> | null;
  selectionDirty: boolean;
  selectionInvalid: boolean;
  source: "buffer" | "index" | null;
  rows: StageRow[];
  rowIds: string[];
  micros: number;
  revision: number;
  diskDoc: Text;
  diffEpoch: number;
}
const wrapConfig = new Compartment();
const pastWrapConfig = new Compartment();
const setDecorations = StateEffect.define<DecorationSet>();
const decorations = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setDecorations)) return e.value;
    return value.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});
const setCorrespondence = StateEffect.define<DecorationSet>();
const correspondence = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    value = value.map(tr.changes);
    for (const e of tr.effects) if (e.is(setCorrespondence)) value = e.value;
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});
function mappedSelection(reverse = false): [number, number][] {
  if (!active) return [];
  const changes = reverse
    ? active.changes.map((c) => ({
        a: c.b,
        aEnd: c.bEnd,
        b: c.a,
        bEnd: c.aEnd,
      }))
    : active.changes;
  const selection = (reverse ? past : editor).state.selection;
  const result: [number, number][] = [];
  for (const r of selection.ranges) {
    if (r.empty) continue;
    let cursor = r.from,
      delta = 0;
    for (const c of changes) {
      if (c.bEnd < r.from) {
        delta = c.aEnd - c.bEnd;
        continue;
      }
      if (c.b >= r.to) break;
      if (cursor < c.b)
        result.push([cursor + delta, Math.min(c.b, r.to) + delta]);
      if (c.bEnd > r.from || c.b === r.from) result.push([c.a, c.aEnd]);
      cursor = Math.max(cursor, c.bEnd);
      delta = c.aEnd - c.bEnd;
    }
    if (cursor < r.to) result.push([cursor + delta, r.to + delta]);
  }
  return result.filter(([a, b]) => b >= a);
}
function reflectPastSelection() {
  editor.dispatch({
    effects: setCorrespondence.of(
      Decoration.set(
        mappedSelection(true).map(([a, b]) =>
          a === b
            ? Decoration.widget({ widget: new Marker(), side: 1 }).range(a)
            : Decoration.mark({ class: "past-focus" }).range(a, b),
        ),
        true,
      ),
    ),
  });
}
class Marker extends WidgetType {
  constructor(
    readonly green = false,
    readonly horizontal = false,
  ) {
    super();
  }
  eq(o: Marker) {
    return o.green === this.green && o.horizontal === this.horizontal;
  }
  toDOM() {
    let s = document.createElement("span");
    s.className =
      "diff-marker" +
      (this.green ? " insert" : "") +
      (this.horizontal ? " line" : "");
    return s;
  }
}
let splitUndo = false,
  lastInputClass = "";
let quitPending: number | null = null;
let operationBusy = false;
const editor = new EditorView({
  parent: $(".now"),
  state: makeState(""),
  dispatchTransactions: (trs) => {
    if (
      (quitPending || operationBusy || active?.locked) &&
      trs.some((tr) => tr.docChanged)
    )
      return;
    const b = active;
    editor.update(trs);
    if (!b) return;
    for (const tr of trs) {
      if (tr.docChanged) {
        b.revision++;
        if (b.selectionDirty) b.selectionInvalid = true;
        b.selection = null;
        b.source = null;
        b.changes = previewChanges(b.changes, b.base, tr);
        b.state = editor.state;
        b.sync.enqueue(tr.changes);
        updateTitle();
        updateFileIndicator(b);
      } else if (tr.selection) splitUndo = true;
    }
    if (trs.some((tr) => tr.docChanged)) {
      scheduleOverview();
      editor.update([
        editor.state.update({
          effects: setDecorations.of(
            marks(b.changes, b.base, editor.state.doc),
          ),
        }),
      ]);
    }
    b.state = editor.state;
    updatePast();
    updateStatus();
  },
});
const past = new EditorView({
  parent: $(".past"),
  state: EditorState.create({
    doc: "",
    extensions: [
      pastViewport,
      keymap.of(defaultKeymap),
      editorStyleNonce(),
      EditorState.lineSeparator.of("\n"),
      lineNumbers(),
      decorations,
      EditorView.updateListener.of((u) => {
        if (u.selectionSet && u.view.hasFocus) {
          reflectPastSelection();
          void updateRestoreEnabled().catch(fail);
        }
      }),
      EditorView.domEventHandlers({
        contextmenu(e, v) {
          if (!active) return false;
          const pos = v.posAtCoords({ x: e.clientX, y: e.clientY });
          const c =
            pos === null
              ? undefined
              : active.changes.find((c) => c.a <= pos && pos < c.aEnd);
          const selected = selectedChanges();
          if (!c && !selected.length) return false;
          e.preventDefault();
          void (selected.length
            ? restoreMenu(selected, true)
            : pastRestoreMenu(c!));
          return true;
        },
      }),
      EditorView.contentAttributes.of({ tabindex: "0" }),
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      pastWrapConfig.of(wrap ? EditorView.lineWrapping : []),
      drawSelection(),
      EditorView.theme(
        { "&": { backgroundColor: "#2b2b30", color: "#d5d5d8" } },
        { dark: true },
      ),
    ],
  }),
});
function makeState(text: string) {
  return EditorState.create({
    doc: text,
    extensions: [
      wholeRowScroll,
      editorStyleNonce(),
      EditorState.lineSeparator.of("\n"),
      lineNumbers(),
      drawSelection(),
      highlightActiveLine(),
      correspondence,
      highlightSelectionMatches(),
      decorations,
      history({
        newGroupDelay: 1e9,
        joinToEvent: (tr, adjacent) =>
          adjacent &&
          (tr.isUserEvent("input.type") || tr.isUserEvent("delete")) &&
          !splitUndo,
      }),
      search({ top: false }),
      wrapConfig.of(wrap ? EditorView.lineWrapping : []),
      keymap.of([...historyKeymap, ...defaultKeymap]),
      EditorView.theme(
        { "&": { backgroundColor: "#242428", color: "#d5d5d8" } },
        { dark: true },
      ),
      EditorState.transactionExtender.of((tr) => {
        if (!tr.docChanged) return null;
        let text = "";
        tr.changes.iterChanges(
          (a, b, _c, _d, t) =>
            (text += t.length ? t.toString() : tr.startState.sliceDoc(a, b)),
        );
        const cls =
          (tr.isUserEvent("delete") ? "delete:" : "input:") +
          (/^\s+$/u.test(text) ? "space" : "word");
        let separate =
          splitUndo ||
          (cls !== lastInputClass &&
            !(lastInputClass === "input:word" && cls === "input:space")) ||
          text.includes("\n") ||
          !(tr.isUserEvent("input.type") || tr.isUserEvent("delete"));
        splitUndo = false;
        lastInputClass = cls;
        return separate ? { annotations: isolateHistory.of("before") } : null;
      }),
      EditorView.domEventHandlers({
        blur() {
          splitUndo = true;
        },
        wheel() {
          splitUndo = true;
        },
        mousedown() {
          splitUndo = true;
        },
        focus() {
          if (past.state.selection.main.from !== past.state.selection.main.to)
            past.dispatch({
              selection: { anchor: past.state.selection.main.head },
            });
          editor.dispatch({ effects: setCorrespondence.of(Decoration.none) });
          updatePast();
        },
        contextmenu(e, v) {
          const pos = v.posAtCoords({ x: e.clientX, y: e.clientY });
          const c =
            pos === null ? undefined : changeAt(active?.changes || [], pos);
          const selected = selectedChanges();
          if (selected.length || (c && c.aEnd > c.a && c.bEnd > c.b)) {
            e.preventDefault();
            void restoreMenu(
              selected.length ? selected : [c!],
              selected.length > 0,
            );
          }
          return false;
        },
      }),
    ],
  });
}
function status(s: string) {
  $(".message").textContent = s;
}
function fail(e: unknown) {
  console.error(e);
  status(String(e));
  void choose(String(e), ["OK"]);
}
function updateCommitButtons() {
  $<HTMLButtonElement>("#stage-selected").disabled =
    operationBusy || !active || !repo?.gitRoot;
  $<HTMLButtonElement>("#commit").disabled =
    operationBusy ||
    !repo?.gitRoot ||
    !$<HTMLInputElement>("#summary").value.trim() ||
    !(
      repo.staged.length || [...buffers.values()].some((b) => b.selectionDirty)
    );
  $<HTMLButtonElement>("#refresh").disabled =
    operationBusy || refreshing || !repo;
}
function busy(s: string | null) {
  operationBusy = !!s;
  $(".sidebar").inert = !!s;
  $(".editor-stack").inert = !!s;
  $(".stage").inert = !!s;
  $(".search").inert = !!s;
  $(".overlay").hidden = !s;
  $("#busy-message").textContent = s || "";
  updateCommitButtons();
  scheduleMenuState();
}
const dialogs = new DialogQueue(presentDialog);
function choose(message: string, choices: string[]) {
  return dialogs.choose(message, choices);
}
function presentDialog(message: string, choices: string[]): Promise<string> {
  return new Promise((resolve) => {
    const d = $<HTMLDialogElement>(".modal");
    $(".modal-message").textContent = message;
    $(".modal-actions").replaceChildren();
    for (const label of choices) {
      const b = document.createElement("button");
      b.textContent = label;
      b.onclick = () => {
        d.close();
        resolve(label);
      };
      $(".modal-actions").append(b);
    }
    d.oncancel = (e) => {
      e.preventDefault();
      d.close();
      resolve("Cancel");
    };
    d.showModal();
  });
}
let storedPreferences = { wrap, whitespace, font, pastHeight };
function persist() {
  pastHeight = Math.max(
    45,
    Math.min(pastHeight, Math.max(45, $(".main").clientHeight - 100)),
  );
  const current = { wrap, whitespace, font, pastHeight };
  try {
    const merged = readPreferences(localStorage);
    for (const key of Object.keys(current) as (keyof typeof current)[]) {
      if (current[key] !== storedPreferences[key])
        Object.assign(merged, { [key]: current[key] });
    }
    localStorage.setItem("preferences", JSON.stringify(merged));
  } catch {
    /* Storage may be unavailable. */
  }
  storedPreferences = current;
  document.documentElement.style.setProperty("--font", `${font}px`);
  $(".past").style.height = "";
  document.documentElement.style.setProperty("--past", `${pastHeight}px`);
}
persist();
function dirty(b: BufferState) {
  return !b.state.doc.eq(b.diskDoc);
}
let representedPath = "";
function updateTitle() {
  scheduleMenuState();
  const path = active && repo ? `${repo.root}/${active.path}` : "";
  if (path !== representedPath) {
    representedPath = path;
    void invoke("document_path", { path }).catch(fail);
  }
  void win.setTitle(
    "DiffEdit" +
      (active ? " — " + active.path + (dirty(active) ? " •" : "") : ""),
  );
}
function updateStatus() {
  scheduleMenuState();
  if (!active) return;
  const p = editor.state.selection.main.head,
    l = editor.state.doc.lineAt(p);
  status(
    `Ln ${l.number}, Col ${p - l.from + 1}  ·  ${active.changes.filter((c) => visible(c, active!.base, editor.state.doc, whitespace)).length} changes${dirty(active) ? "  ·  Unsaved" : ""}`,
  );
}
const fileElements = new Map<string, HTMLElement>();
function updateFileIndicator(b: BufferState) {
  const el = fileElements.get(b.path);
  if (el) {
    const dot = el.querySelector(".dirty");
    if (dot) dot.textContent = dirty(b) ? "●" : "";
  }
}
async function pickFolder() {
  const p = await open({ directory: true, multiple: false });
  if (typeof p === "string") await openFolder(p);
}
async function openFolder(root: string, routed = false) {
  if (operationBusy) return;
  busy("Opening folder…");
  try {
    if (!routed) {
      const selected = await invoke<string | null>("route_folder", {
        root,
        reuse: !repo,
      });
      if (selected === null || repo?.root === selected) return;
      root = selected;
    }
    if (refreshFlight) await refreshFlight;
    if (buffers.size && !(await canClose())) return;
    await Promise.all([...releases.values()]);
    for (const b of buffers.values()) await flush(b);
    ++opening;
    const opened = await invoke<Repo>("open_folder", { root });
    buffers.clear();
    repo = opened;
    active = null;
    currentMode = "edit";
    $("#edit-mode").setAttribute("aria-pressed", "true");
    $("#commit-mode").setAttribute("aria-pressed", "false");
    $(".search").hidden = true;
    $(".commit-box").hidden = true;
    $("#branch").hidden = true;
    editor.setState(makeState(""));
    $(".editor-stack").hidden = true;
    $(".stage").hidden = true;
    $(".placeholder").hidden = false;
    $<HTMLButtonElement>("#edit-mode").disabled = false;
    $<HTMLButtonElement>("#commit-mode").disabled = !repo.gitRoot;
    $("#branch").textContent = `Branch: ${repo.branch}`;
    expanded.clear();
    await invoke("remember_folder", { root: repo.root }).catch(console.error);
    renderTree();
    status(`${repo.files.length} files · ${repo.changed.length} changed`);
    updateTitle();
  } finally {
    busy(null);
  }
}
let rootExpanded = true;
function folderCaption(
  button: HTMLElement,
  label: string,
  expanded: boolean,
  changed = false,
) {
  button.setAttribute("aria-expanded", String(expanded));
  const arrow = document.createElement("span");
  arrow.className = "tree-leading disclosure";
  arrow.setAttribute("aria-hidden", "true");
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = label;
  button.append(arrow, name);
  if (changed) {
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.textContent = "●";
    button.append(dot);
  }
}
let membershipRepo: Repo | null = null;
let changedPaths = new Set<string>(),
  stagedPaths = new Set<string>();
function repoMembership() {
  if (membershipRepo !== repo) {
    membershipRepo = repo;
    changedPaths = new Set(repo?.changed);
    stagedPaths = new Set(repo?.staged);
  }
}
function renderTree() {
  updateCommitButtons();
  repoMembership();
  const tree = $(".tree");
  fileElements.clear();
  tree.replaceChildren();
  if (!repo) return;
  const root = document.createElement("button");
  folderCaption(
    root,
    repo.root.split("/").filter(Boolean).at(-1)!,
    rootExpanded,
    !rootExpanded &&
      !!(repo.changed.length || [...buffers.values()].some(dirty)),
  );
  root.onclick = () => {
    rootExpanded = !rootExpanded;
    renderTree();
  };
  tree.append(root);
  if (!rootExpanded) return;
  const shownDirs = new Set<string>();
  const changed = (p: string) =>
    changedPaths.has(p) || !!(buffers.has(p) && dirty(buffers.get(p)!));
  const files = mode() === "stage" ? repo.files.filter(changed) : repo.files;
  $(".root").textContent =
    mode() === "stage" ? `CHANGES (${files.length})` : "FOLDERS";
  for (const path of files) {
    const parts = path.split("/");
    let hidden = false;
    for (let i = 0; i < parts.length - 1; i++) {
      const dir = parts.slice(0, i + 1).join("/");
      if (!shownDirs.has(dir)) {
        shownDirs.add(dir);
        let el = document.createElement("button");
        el.style.paddingLeft = `${(i + 1) * 16 + 6}px`;
        folderCaption(
          el,
          parts[i],
          expanded.has(dir),
          !expanded.has(dir) &&
            files.some((p) => p.startsWith(dir + "/") && changed(p)),
        );
        el.onclick = () => {
          expanded.has(dir) ? expanded.delete(dir) : expanded.add(dir);
          renderTree();
        };
        tree.append(el);
      }
      if (!expanded.has(dir)) {
        hidden = true;
        break;
      }
    }
    if (hidden) continue;
    const el = document.createElement("button");
    el.dataset.path = path;
    fileElements.set(path, el);
    el.classList.toggle("active", active?.path === path);
    el.style.paddingLeft = `${parts.length * 16 + 6}px`;
    const leading = document.createElement("span");
    leading.className = "tree-leading";
    el.append(leading);
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = parts.at(-1)!;
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.textContent = changedPaths.has(path) ? "●" : "";
    const unsaved = document.createElement("span");
    unsaved.className = "dirty";
    unsaved.textContent =
      buffers.has(path) && dirty(buffers.get(path)!) ? "●" : "";
    if (mode() === "stage") {
      const check = document.createElement("input");
      check.type = "checkbox";
      const b = buffers.get(path);
      const ids = b?.rowIds || [];
      const count = ids.filter((id) => b?.selection?.has(id)).length;
      check.checked =
        b?.selection === null || !b
          ? stagedPaths.has(path)
          : ids.length > 0 && count === ids.length;
      check.indeterminate =
        (!b?.selectionDirty && !!repo?.partialStaged?.includes(path)) ||
        (count > 0 && count < ids.length);
      check.onclick = (e) => {
        e.stopPropagation();
        const all = check.checked;
        void (async () => {
          await activate(path);
          if (!active || active.path !== path) return;
          active.source = "buffer";
          active.selection = null;
          await loadStage(active);
          active.selection = new Set(all ? active.rowIds : []);
          active.selectionDirty = true;
          active.selectionInvalid = false;
          await renderStage();
          renderTree();
        })().catch(fail);
      };
      leading.append(check);
    }
    el.append(name, dot, unsaved);
    el.onclick = () => void activate(path).catch(fail);
    tree.append(el);
  }
}
async function activate(path: string) {
  if (operationBusy) return;
  const id = ++opening;
  // Reselecting a file is a focus action, not a document switch. Reinstalling
  // its state resets CodeMirror's layout/scroll anchor and can move the viewport
  // again after the saved scrollTop has already been restored.
  if (active?.path === path) {
    if (mode() === "edit") editor.focus();
    return;
  }
  if (active) {
    active.state = editor.state;
    active.scroll = editor.scrollDOM.scrollTop;
  }
  const b = await loadBuffer(path);
  if (id !== opening) return;
  past.contentDOM.blur();
  if (active && active !== b) active.rows = [];
  active = b;
  buffers.delete(path);
  buffers.set(path, b);
  if (!refreshing) trimBuffers();
  splitUndo = true;
  lastInputClass = "";
  editor.setState(b.state);
  if (!$(".search").hidden) updateQuery();
  editor.dispatch({
    effects: wrapConfig.reconfigure(wrap ? EditorView.lineWrapping : []),
  });
  $(".placeholder").hidden = true;
  showMode();
  rootExpanded = true;
  const parts = path.split("/");
  for (let i = 1; i < parts.length; i++)
    expanded.add(parts.slice(0, i).join("/"));
  renderTree();
  $(".tree .active")?.scrollIntoView({ block: "nearest" });
  applyDiff(b);
  editor.scrollDOM.scrollTop = b.scroll;
  updateTitle();
  updateStatus();
  editor.focus();
}
const releases = new Map<string, Promise<void>>();
function trimBuffers() {
  // Histories and user work are never silently discarded. Bound the reusable
  // clean cache by both document count and approximate UTF-16 storage size.
  let size = [...buffers.values()].reduce(
    (n, b) => n + b.base.length + b.state.doc.length + b.diskDoc.length,
    0,
  );
  for (const [path, b] of buffers) {
    if (buffers.size <= 32 && size <= 16 * 1024 * 1024) break;
    if (
      b === active ||
      b.locked ||
      dirty(b) ||
      b.selectionDirty ||
      b.selectionInvalid ||
      undoDepth(b.state) ||
      redoDepth(b.state)
    )
      continue;
    buffers.delete(path);
    size -= b.base.length + b.state.doc.length + b.diskDoc.length;
    const release = (async () => {
      try {
        await flush(b);
        await invoke("release_document", { path, version: b.version });
      } catch (error) {
        // Retain the frontend identity if releasing failed, including history.
        if (!buffers.has(path)) buffers.set(path, b);
        status(`Could not release ${path}: ${error}`);
      } finally {
        releases.delete(path);
      }
    })();
    releases.set(path, release);
  }
}
async function loadBuffer(path: string): Promise<BufferState> {
  return buffers.load(path, async () => {
    await releases.get(path);
    const retained = buffers.get(path);
    if (retained) return retained;
    const d = await invoke<Document>("open_document", { path });
    const { text, ...snapshot } = d;
    const b: BufferState = {
      ...snapshot,
      state: makeState(text),
      changes: [],
      scroll: 0,
      selection: null,
      selectionDirty: false,
      selectionInvalid: false,
      source: null,
      rows: [],
      rowIds: [],
      micros: 0,
      revision: 0,
      diffEpoch: 0,
      index: "",
      locked: false,
      diskDoc: Text.of((d.disk ?? "").split("\n")),
      sync: null!,
    };
    b.sync = new DocumentSync({
      path,
      version: () => b.version,
      text: () => b.state.doc.toString(),
      invoke,
      receive: (result, current) => {
        b.version = result.version;
        if (current && result.head === b.head) {
          b.changes = result.diff.changes;
          b.diffEpoch++;
          b.micros = result.diff.micros;
          if (active === b) applyDiff(b);
        }
      },
      fail,
    });
    const u = await invoke<DiffUpdate>("document_diff", { path });
    if (u.head === b.head) {
      b.changes = u.diff.changes;
      b.micros = u.diff.micros;
    }
    return b;
  });
}
function flush(b: BufferState) {
  return b.sync.flush();
}
function marks(
  changes: Change[],
  base: string,
  current: Text,
  pastSide = false,
): DecorationSet {
  const list = [];
  for (const c of changes) {
    if (!visible(c, base, current, whitespace)) continue;
    const from = pastSide ? c.a : c.b,
      to = pastSide ? c.aEnd : c.bEnd;
    if (to > from)
      list.push(
        Decoration.mark({ class: pastSide ? "deletion" : "addition" }).range(
          from,
          to,
        ),
      );
    else if (!pastSide && c.aEnd > c.a) {
      const old = base.slice(c.a, c.aEnd);
      const horizontal = old.includes("\n") && !/\S/u.test(old);
      list.push(
        Decoration.widget({
          widget: new Marker(false, horizontal),
          side: -1,
        }).range(from),
      );
    }
  }
  return Decoration.set(list, true);
}
function applyDiff(b: BufferState) {
  if (active !== b) return;
  const text = editor.state.doc;
  editor.dispatch({
    effects: setDecorations.of(marks(b.changes, b.base, text)),
  });
  b.state = editor.state;
  updatePast();
  scheduleOverview();
  updateStatus();
  void updateRestoreEnabled();
}
let pastMarks: {
  buffer: BufferState;
  revision: number;
  epoch: number;
  whitespace: boolean;
  marks: DecorationSet;
} | null = null;
let lastPastKey = "";
let pastScrollFocus = "";
let lastPastBase = "";
function updatePast() {
  const b = active;
  if (!b || (past.hasFocus && lastPastBase === b.base)) return;
  if (past.hasFocus) past.contentDOM.blur();
  const pos = editor.state.selection.main.head,
    c = changeAt(b.changes, pos);
  let target = basePosition(b.changes, pos),
    focus: [number, number] = wordRange(b.base, target),
    deleted = false,
    green = false;
  if (c && visible(c, b.base, editor.state.doc, whitespace)) {
    if (c.aEnd > c.a) {
      focus = [c.a, c.aEnd];
      deleted = true;
      target = c.a;
    } else {
      focus = [c.a, c.a];
      green = true;
      target = c.a;
    }
  }
  const ranges = mappedSelection();
  const scrollFocus = JSON.stringify([b.path, focus, green, ranges]);
  const movePast = scrollFocus !== pastScrollFocus || b.base !== lastPastBase;
  const key = JSON.stringify([
    b.path,
    b.head,
    b.diffEpoch,
    b.revision,
    focus,
    green,
    whitespace,
    editor.state.selection.toJSON(),
  ]);
  if (key === lastPastKey) return;
  const baseChanged = lastPastBase !== b.base;
  // Derive decorations from this buffer, never from the previously active file.
  if (
    !pastMarks ||
    pastMarks.buffer !== b ||
    pastMarks.revision !== b.revision ||
    pastMarks.epoch !== b.diffEpoch ||
    pastMarks.whitespace !== whitespace
  ) {
    pastMarks = {
      buffer: b,
      revision: b.revision,
      epoch: b.diffEpoch,
      whitespace,
      marks: marks(b.changes, b.base, editor.state.doc, true),
    };
  }
  const d = pastMarks.marks;
  const extra = ranges.length
    ? ranges.map(([a, b]) =>
        a === b
          ? Decoration.widget({ widget: new Marker(true), side: 1 }).range(a)
          : Decoration.mark({
              class:
                "past-focus" +
                (active!.changes.some((c) => c.a === a && c.aEnd === b)
                  ? " deleted"
                  : ""),
            }).range(a, b),
      )
    : focus[1] > focus[0]
      ? [
          Decoration.mark({
            class: "past-focus" + (deleted ? " deleted" : ""),
          }).range(...focus),
        ]
      : green
        ? [
            Decoration.widget({ widget: new Marker(true), side: 1 }).range(
              target,
            ),
          ]
        : [];
  past.dispatch({
    ...(baseChanged
      ? {
          changes: { from: 0, to: past.state.doc.length, insert: b.base },
          selection: { anchor: 0 },
        }
      : {}),
    effects: [
      setDecorations.of(d.update({ add: extra, sort: true })),
      ...(movePast
        ? [
            EditorView.scrollIntoView(
              ranges.length
                ? EditorSelection.range(
                    ranges.reduce(
                      (min, [start]) => Math.min(min, start),
                      Infinity,
                    ),
                    ranges.reduce((max, [, end]) => Math.max(max, end), 0),
                  )
                : Math.min(target, b.base.length),
              {
                y: "center",
                x: "nearest",
              },
            ),
          ]
        : []),
    ],
  });
  pastScrollFocus = scrollFocus;
  lastPastKey = key;
  lastPastBase = b.base;
  void updateRestoreEnabled();
}
let overviewFrame = 0;
function scheduleOverview() {
  cancelAnimationFrame(overviewFrame);
  overviewFrame = requestAnimationFrame(updateOverview);
}
function updateOverview() {
  const el = $(".overview");
  el.replaceChildren();
  if (!active) return;
  const height = Math.max(1, editor.contentHeight);
  const current = editor.state.doc;
  for (const c of active.changes) {
    if (!visible(c, active.base, current, whitespace)) continue;
    const tick = document.createElement("i");
    tick.className =
      c.aEnd > c.a ? (c.bEnd > c.b ? "mixed" : "deleted") : "inserted";
    tick.style.top = `${Math.min(100, (editor.lineBlockAt(c.b).top / height) * 100)}%`;
    tick.onpointerdown = (e) => {
      if (operationBusy) return;
      e.stopPropagation();
      e.preventDefault();
      jump(c.b);
    };
    el.append(tick);
  }
  const thumb = document.createElement("div");
  thumb.className = "overview-thumb";
  el.append(thumb);
  updateOverviewThumb();
}
function updateOverviewThumb() {
  const thumb = $(".overview-thumb");
  if (!thumb) return;
  const scroller = editor.scrollDOM,
    height = Math.max(1, scroller.scrollHeight),
    ratio = scroller.clientHeight / height;
  const size = Math.min(
    100,
    Math.max(
      (28 / Math.max(1, $(".overview").clientHeight)) * 100,
      ratio * 100,
    ),
  );
  thumb.style.height = `${size}%`;
  thumb.style.top = `${(scroller.scrollTop / Math.max(1, height - scroller.clientHeight)) * (100 - size)}%`;
}
editor.scrollDOM.addEventListener(
  "scroll",
  () => {
    updateOverviewThumb();
  },
  { passive: true },
);
$(".overview").onpointerdown = (e) => {
  if (operationBusy) return;
  splitUndo = true;
  const el = $(".overview");
  el.setPointerCapture(e.pointerId);
  const bounds = el.getBoundingClientRect();
  const thumb = $(".overview-thumb");
  const thumbHeight = thumb?.getBoundingClientRect().height ?? 0;
  const grab =
    e.target === thumb
      ? e.clientY - thumb.getBoundingClientRect().top
      : thumbHeight / 2;
  const move = (event: PointerEvent) => {
    const scroller = editor.scrollDOM;
    const fraction = Math.max(
      0,
      Math.min(
        1,
        (event.clientY - bounds.top - grab) /
          Math.max(1, bounds.height - thumbHeight),
      ),
    );
    scroller.scrollTop =
      fraction * Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    updateOverviewThumb();
  };
  e.preventDefault();
  move(e);
  el.onpointermove = move;
  const end = () => {
    el.onpointermove = null;
    el.onpointerup = null;
    el.onpointercancel = null;
  };
  el.onpointerup = end;
  el.onpointercancel = end;
};
let overviewResizeFrame = 0;
new ResizeObserver(() => {
  cancelAnimationFrame(overviewResizeFrame);
  overviewResizeFrame = requestAnimationFrame(() => updateOverview());
}).observe($(".now"));
function jump(pos: number) {
  editor.dispatch({
    selection: { anchor: Math.max(0, Math.min(pos, editor.state.doc.length)) },
    effects: EditorView.scrollIntoView(
      Math.max(0, Math.min(pos, editor.state.doc.length)),
      { y: "center" },
    ),
  });
  editor.focus();
}
function selectedChanges(): Change[] {
  if (!active) return [];
  const reverse = past.hasFocus;
  return active.changes.filter((change) => {
    const c = reverse ? { b: change.a, bEnd: change.aEnd } : change;
    return (reverse ? past : editor).state.selection.ranges.some(
      (r) =>
        !r.empty &&
        (c.b === c.bEnd
          ? c.b >= r.from && c.b < r.to
          : c.b < r.to && c.bEnd > r.from),
    );
  });
}
function restoreChanges(changes: Change[]) {
  if (!active || !changes.length) return;
  editor.dispatch({
    changes: changes.map((c) => ({
      from: c.b,
      to: c.bEnd,
      insert: active!.base.slice(c.a, c.aEnd),
    })),
    annotations: [
      Transaction.userEvent.of("input.restore"),
      isolateHistory.of("full"),
    ],
  });
  editor.focus();
}
function restore(c?: Change) {
  if (!active) return;
  const selected = selectedChanges();
  if (!c && selected.length) {
    restoreChanges(selected);
    return;
  }
  c ??= past.hasFocus
    ? active.changes.find(
        (c) =>
          c.a <= past.state.selection.main.head &&
          past.state.selection.main.head <= c.aEnd,
      )
    : changeAt(active.changes, editor.state.selection.main.head);
  if (c) restoreChanges([c]);
}
async function restoreMenu(changes: Change[], selection = false) {
  if (!active) return;
  const buffer = active,
    epoch = active.diffEpoch,
    revision = active.revision;
  const item = await MenuItem.new({
    text: selection
      ? `Restore ${changes.length} ${changes.length === 1 ? "change" : "changes"}`
      : `Restore '${active.base.slice(changes[0].a, changes[0].aEnd)}'`,
    action: () => {
      if (
        active === buffer &&
        active.revision === revision &&
        active.diffEpoch === epoch
      )
        restoreChanges(changes);
    },
  });
  const menu = await Menu.new({ items: [item] });
  await menu.popup();
}
async function pastRestoreMenu(c: Change) {
  if (!active) return;
  const buffer = active,
    epoch = active.diffEpoch,
    revision = active.revision;
  const item = await MenuItem.new({
    text: c.b === c.bEnd ? "Keep" : "Restore",
    action: () => {
      if (
        active === buffer &&
        active.revision === revision &&
        active.diffEpoch === epoch
      )
        restoreChanges([c]);
    },
  });
  await (await Menu.new({ items: [item] })).popup();
}
let restoreEnabled = false;
async function updateRestoreEnabled() {
  const c =
    active && changeAt(active.changes, editor.state.selection.main.head);
  const enabled = !!c || selectedChanges().length > 0;
  if (enabled !== restoreEnabled) {
    restoreEnabled = enabled;
    await syncMenuState();
  }
}
async function save(b = active) {
  if (!b) return;
  await flush(b);
  try {
    const d = await invoke<Pick<Document, "disk">>("save_document", {
      path: b.path,
    });
    b.disk = d.disk;
    b.diskDoc = Text.of((d.disk ?? "").split("\n"));
    if (active === b) {
      updateTitle();
      updateStatus();
    }
    if (repo) {
      try {
        repo = await invoke<Repo>("refresh");
        if (!repo.gitRoot) await inspectBuffer(b);
      } catch (error) {
        status(`Saved ${b.path}. Status refresh failed: ${error}`);
      }
    }
    renderTree();
  } catch (e) {
    if (String(e).includes("EXTERNAL_CHANGE")) {
      const choice = await choose(
        `${b.path} changed on disk. Reload it, overwrite with your buffer, or cancel?`,
        ["Cancel", "Reload", "Overwrite"],
      );
      if (choice === "Cancel") return false;
      await resolve(b, choice === "Reload");
      if (choice === "Overwrite") return save(b);
    } else throw e;
  }
  return true;
}
async function resolve(b: BufferState, reload: boolean) {
  const wasLocked = b.locked;
  b.locked = true;
  try {
    await flush(b);
    const result = await invoke<{
      document: Document;
      diff: DiffUpdate["diff"];
    }>("resolve_document", {
      path: b.path,
      reload,
      version: b.version,
    });
    const d = result.document;
    b.changes = result.diff.changes;
    b.micros = result.diff.micros;
    b.diffEpoch++;
    b.disk = d.disk;
    b.diskDoc = Text.of((d.disk ?? "").split("\n"));
    b.base = d.base;
    b.baseExists = d.baseExists;
    b.head = d.head;
    b.version = d.version;
    if (reload) {
      if (b.selectionDirty) b.selectionInvalid = true;
      b.selection = null;
      b.source = null;
      const head = b.state.selection.main.head;
      const scroll = active === b ? editor.scrollDOM.scrollTop : b.scroll;
      b.state = makeState(d.text);
      b.state = b.state.update({
        selection: { anchor: Math.min(head, b.state.doc.length) },
      }).state;
      b.revision++;
      if (active === b) {
        editor.setState(b.state);
        editor.scrollDOM.scrollTop = scroll;
      }
    }
    if (active === b) applyDiff(b);
    updateTitle();
    renderTree();
  } finally {
    b.locked = wasLocked;
  }
}
async function saveAll() {
  for (const b of buffers.values())
    if (dirty(b) && !(await save(b))) return false;
  return true;
}
async function canClose() {
  const names = [...buffers.values()].filter(dirty).map((b) => b.path);
  if (!names.length) return true;
  const c = await choose(
    `Save changes before closing?\n\n${names.join("\n")}`,
    ["Cancel", "Discard", "Save All"],
  );
  return c === "Discard" || (c === "Save All" && (await saveAll()));
}
let refreshFlight: Promise<void> | null = null;
function foreground(force = false): Promise<void> {
  if (operationBusy && !force) return Promise.resolve();
  if (refreshFlight) return refreshFlight;
  refreshFlight = performForeground().finally(() => {
    refreshFlight = null;
  });
  return refreshFlight;
}
async function inspectBuffer(b: BufferState) {
  // Inspection does not block typing. Retry obsolete snapshots and install
  // the baseline and its derived ranges in one synchronous step.
  while (true) {
    await flush(b);
    const revision = b.revision;
    const d = await invoke<
      Omit<Document, "path" | "text"> & {
        diff: DiffUpdate["diff"] | null;
      }
    >("inspect_document", { path: b.path, head: b.head });
    if (revision !== b.revision || d.version !== b.version) continue;
    if (
      b.base !== d.base ||
      b.baseExists !== d.baseExists ||
      b.head !== d.head
    ) {
      if (b.selectionDirty) b.selectionInvalid = true;
      b.selection = null;
      b.source = null;
    }
    b.base = d.base;
    b.baseExists = d.baseExists;
    b.head = d.head;
    if (d.diff) {
      b.changes = d.diff.changes;
      b.micros = d.diff.micros;
      b.diffEpoch++;
    }
    if (active === b && d.diff) applyDiff(b);
    if (d.disk !== b.disk) {
      if (dirty(b)) {
        const c = await choose(
          `${b.path} was changed or deleted outside DiffEdit.`,
          ["Cancel", "Keep Buffer", "Reload"],
        );
        if (c !== "Cancel") await resolve(b, c === "Reload");
      } else await resolve(b, true);
    }
    break;
  }
}
async function performForeground() {
  if (!repo || refreshing || closing) return;
  refreshing = true;
  updateCommitButtons();
  scheduleMenuState();
  try {
    const previousIndex = repo.index;
    repo = await invoke<Repo>("refresh");
    if (repo.index !== previousIndex) {
      for (const b of buffers.values()) {
        if (b.selectionDirty) b.selectionInvalid = true;
        b.selection = null;
        b.source = null;
        b.index = "";
      }
    }
    $("#branch").textContent = `Branch: ${repo.branch}`;
    const errors: string[] = [];
    for (const b of buffers.values()) {
      try {
        await inspectBuffer(b);
      } catch (error) {
        errors.push(`${b.path}: ${error}`);
      }
    }
    renderTree();
    if (errors.length) throw Error(errors.join("\n"));
    if (mode() === "stage" && active) await renderStage();
  } finally {
    refreshing = false;
    updateCommitButtons();
  }
}
function showSearch(replace = false) {
  if (!active || mode() !== "edit") return;
  $(".search").hidden = false;
  $("#replace-row").hidden = !replace;
  const field = $<HTMLInputElement>("#query");
  const s = editor.state.sliceDoc(
    editor.state.selection.main.from,
    editor.state.selection.main.to,
  );
  if (s && !s.includes("\n")) field.value = s;
  updateQuery();
  field.focus();
  field.select();
}
function updateQuery() {
  if (!active) return;
  editor.dispatch({
    effects: setSearchQuery.of(
      new SearchQuery({
        search: $<HTMLInputElement>("#query").value,
        replace: $<HTMLInputElement>("#replacement").value,
        caseSensitive: false,
        literal: true,
      }),
    ),
  });
}
function searchMove(back = false) {
  if (!active || mode() !== "edit") return;
  if (!$<HTMLInputElement>("#query").value) {
    showSearch();
    return;
  }
  updateQuery();
  const before = editor.state.selection.main;
  const found = (back ? findPrevious : findNext)(editor);
  const after = editor.state.selection.main;
  $("#matches").textContent = !found
    ? "No matches"
    : (back ? after.from >= before.from : after.from <= before.from)
      ? "Wrapped"
      : "";
  updatePast();
}
function closeSearch() {
  $(".search").hidden = true;
  editor.focus();
}
let quickGeneration = 0,
  quickFiltering = false;
function quickOpen() {
  quickPaths = [];
  quickIndex = 0;
  $<HTMLInputElement>("#quick-query").value = "";
  $<HTMLDialogElement>(".quick").showModal();
  $("#quick-query").focus();
  void filterQuick();
}
async function filterQuick() {
  const generation = ++quickGeneration;
  quickFiltering = true;
  try {
    const paths = await invoke<string[]>("quick_matches", {
      query: $<HTMLInputElement>("#quick-query").value,
    });
    if (generation !== quickGeneration) return;
    quickPaths = paths;
    quickIndex = 0;
    $(".quick-list").scrollTop = 0;
    quickFiltering = false;
    renderQuick();
  } catch (e) {
    if (generation === quickGeneration) {
      quickFiltering = false;
      fail(e);
    }
  }
}
function quickMatches() {
  return quickPaths;
}
function renderQuick() {
  const el = $(".quick-list"),
    height = 28;
  const start = Math.max(0, Math.floor(el.scrollTop / height) - 4);
  const end = Math.min(
    quickPaths.length,
    start + Math.ceil((el.clientHeight || 340) / height) + 8,
  );
  const list = document.createElement("div");
  list.style.height = `${quickPaths.length * height}px`;
  list.style.position = "relative";
  for (let i = start; i < end; i++) {
    const b = document.createElement("button");
    b.textContent = quickPaths[i];
    b.classList.toggle("selected", i === quickIndex);
    b.style.cssText = `position:absolute;top:${i * height}px;height:${height}px;width:100%`;
    b.onclick = () => {
      if (quickFiltering || operationBusy) return;
      $(".quick").dispatchEvent(new Event("close"));
      $<HTMLDialogElement>(".quick").close();
      void activate(quickPaths[i]).catch(fail);
    };
    list.append(b);
  }
  el.replaceChildren(list);
}
$(".quick-list").onscroll = () => renderQuick();
async function navigate(direction: number, file = false) {
  repoMembership();
  if (!repo) return;
  const paths = repo.files.filter(
    (p) =>
      changedPaths.has(p) || (buffers.has(p) && buffers.get(p)!.changes.length),
  );
  if (!file && active) {
    const pos = editor.state.selection.main.head;
    const text = editor.state.doc;
    const candidates = active.changes.filter(
      (c) =>
        visible(c, active!.base, text, whitespace) &&
        (direction > 0 ? c.b > pos : c.b < pos),
    );
    const c = direction > 0 ? candidates[0] : candidates.at(-1);
    if (c) {
      jump(c.b);
      return;
    }
  }
  if (!paths.length) return;
  const i = active ? paths.indexOf(active.path) : -1;
  const target =
    paths[
      i < 0
        ? direction > 0
          ? 0
          : paths.length - 1
        : (i + direction + paths.length) % paths.length
    ];
  await activate(target);
  if (!active || active.path !== target) return;
  const current = editor.state.doc;
  const changes = active.changes.filter((c) =>
    visible(c, active!.base, current, whitespace),
  );
  const c = direction > 0 ? changes[0] : changes.at(-1);
  if (c) jump(c.b);
}
async function navigateLocal(direction: number, byLine: boolean) {
  if (!active) return;
  await flush(active);
  const lines = new Set<number>();
  const currentText = editor.state.doc;
  for (const c of active.changes) {
    if (!visible(c, active.base, currentText, whitespace)) continue;
    const start = editor.state.doc.lineAt(c.b).number,
      end = editor.state.doc.lineAt(Math.max(c.b, c.bEnd - 1)).number;
    for (let n = start; n <= end; n++) lines.add(n);
  }
  let targets = [...lines].sort((a, b) => a - b);
  if (!byLine)
    targets = targets.filter((n, i, all) => i === 0 || all[i - 1] !== n - 1);
  if (!targets.length) return;
  const current = editor.state.doc.lineAt(
    editor.state.selection.main.head,
  ).number;
  const target =
    direction > 0
      ? (targets.find((n) => n > current) ?? targets[0])
      : ([...targets].reverse().find((n) => n < current) ?? targets.at(-1)!);
  jump(editor.state.doc.line(target).from);
}
function paragraph(direction: number) {
  const s = editor.state.doc.toString(),
    p = editor.state.selection.main.head;
  if (direction > 0) {
    const match = /\n\s*\n/g;
    match.lastIndex = p + 1;
    const m = match.exec(s);
    jump(m ? m.index + m[0].length : s.length);
  } else {
    const matches = Array.from(
      s.slice(0, Math.max(0, p - 1)).matchAll(/\n\s*\n/g),
    );
    const m = matches.at(-1);
    jump(m ? m.index! + m[0].length : 0);
  }
}
let currentMode = "edit";
function mode() {
  return currentMode;
}
function setMode(value: string) {
  if (operationBusy || !repo || (value === "stage" && !repo.gitRoot)) return;
  currentMode = value;
  $("#edit-mode").setAttribute("aria-pressed", String(value === "edit"));
  $("#commit-mode").setAttribute("aria-pressed", String(value === "stage"));
  showMode();
}
function showMode() {
  scheduleMenuState();
  const staging = mode() === "stage";
  if (staging) $(".search").hidden = true;
  $(".commit-box").hidden = !staging;
  $("#branch").hidden = !staging;
  renderTree();
  $(".editor-stack").hidden = !active || staging;
  $(".stage").hidden = !active || !staging;
  if (active && staging) void renderStage().catch(fail);
  if (!staging) {
    ++stageGeneration;
    clearVirtualRows($(".stage"));
    if (active) active.rows = [];
    updatePast();
    // Editors may have been initialized or switched while their container was hidden.
    editor.requestMeasure();
    past.requestMeasure();
  }
}
async function loadStage(b: BufferState) {
  await flush(b);
  const revision = b.revision,
    head = b.head;
  const snapshot = await invoke<StageSnapshot>("stage_rows", {
    path: b.path,
    source: b.source,
  });
  if (
    b.revision !== revision ||
    b.head !== head ||
    snapshot.version !== b.version ||
    snapshot.head !== b.head
  )
    throw Error("Document changed during staging review; try again");
  const available = new Set(snapshot.rows.flatMap((r) => (r.id ? [r.id] : [])));
  if (b.index && b.index !== snapshot.index && b.selectionDirty) {
    b.selectionInvalid = true;
    b.selection = null;
  }
  if (b.selection === null) b.selection = new Set(snapshot.selected);
  else if ([...b.selection].some((id) => !available.has(id))) {
    b.selectionInvalid = true;
    b.selection = new Set(snapshot.selected);
  }
  b.source = snapshot.source ?? "buffer";
  b.rows = snapshot.rows;
  b.rowIds = [...available];
  b.index = snapshot.index;
}
function selectionFor(b: BufferState) {
  return {
    path: b.path,
    source: b.source ?? "buffer",
    version: b.version,
    head: b.head,
    selected: [...(b.selection ?? [])],
  };
}
let stageGeneration = 0;
async function renderStage() {
  const generation = ++stageGeneration;
  clearVirtualRows($(".stage"));
  const b = active;
  if (!b) return;
  await flush(b);
  const revision = b.revision;
  await loadStage(b);
  if (
    generation !== stageGeneration ||
    active !== b ||
    b.revision !== revision ||
    mode() !== "stage"
  )
    return;
  if (b.selectionInvalid) {
    status(
      "Pending selection was reset because its contents changed. Review and select the lines again.",
    );
    b.selectionInvalid = false;
    b.selectionDirty = false;
  }
  const rows = b.rows;
  const source = document.createElement("select");
  source.setAttribute("aria-label", "Review version");
  for (const [value, label] of [
    ["buffer", "Buffer changes"],
    ["index", "Staged version"],
  ]) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    source.append(option);
  }
  source.value = b.source ?? "buffer";
  source.onchange = () => {
    b.source = source.value as "buffer" | "index";
    b.selection = null;
    b.selectionDirty = false;
    void renderStage().catch(fail);
  };
  $("#review-source").replaceChildren(source);
  const el = $(".stage");
  el.replaceChildren();
  let paint: boolean | null = null;
  let lastPaint = -1;
  const setters = new Map<number, (v: boolean, render?: boolean) => void>();
  const displayed: (number | null)[] = [];
  let lastChange = -100,
    nextChange = 0;
  const changed = rows.flatMap((r, i) => (r.id ? [i] : []));
  let gap = false;
  rows.forEach((r, i) => {
    while (nextChange < changed.length && changed[nextChange] < i)
      lastChange = changed[nextChange++];
    const near =
      i - lastChange <= 3 || (changed[nextChange] ?? Infinity) - i <= 3;
    if (r.kind === "equal" && !near) {
      if (!gap) displayed.push(null);
      gap = true;
    } else {
      displayed.push(i);
      gap = false;
    }
  });
  virtualRows(
    el,
    displayed.length,
    Math.max(23, font * 1.55 + 6),
    (index) => {
      const i = displayed[index];
      if (i === null) {
        const gap = document.createElement("div");
        gap.textContent = "             ⋯";
        return gap;
      }
      const r = rows[i];
      const row = document.createElement("div");
      row.className = "stage-row " + r.kind;
      const check = document.createElement("input");
      check.type = "checkbox";
      check.disabled = !r.id;
      check.checked = !!r.id && b.selection!.has(r.id);
      check.style.visibility = r.id ? "visible" : "hidden";
      row.classList.toggle("off", !!r.id && !check.checked);
      const numbers = document.createElement("span");
      numbers.className = "numbers";
      numbers.textContent = `${r.oldLine ?? ""} ${r.newLine ?? ""}`;
      const code = document.createElement("span");
      code.className = "code";
      code.textContent =
        (r.kind === "delete" ? "−" : r.kind === "insert" ? "+" : " ") +
        r.text.replace(/\n$/, "");
      row.append(check, numbers, code);
      const set = (v: boolean, render = true) => {
        if (!r.id) return;
        b.selectionDirty = true;
        v ? b.selection!.add(r.id) : b.selection!.delete(r.id);
        check.checked = v;
        row.classList.toggle("off", !v);
        if (render) renderTree();
      };
      setters.set(i, set);
      row.onpointerdown = (e) => {
        if (!r.id || e.button !== 0) return;
        e.preventDefault();
        const resetPaint = () => {
          paint = null;
          window.removeEventListener("pointerup", resetPaint);
          window.removeEventListener("pointercancel", resetPaint);
        };
        window.addEventListener("pointerup", resetPaint);
        window.addEventListener("pointercancel", resetPaint);
        lastPaint = i;
        paint = !check.checked;
        set(paint);
      };
      row.onpointerenter = (e) => {
        if (e.buttons === 1 && paint !== null) {
          for (
            let j = Math.min(lastPaint, i);
            j <= Math.max(lastPaint, i);
            j++
          ) {
            const id = rows[j].id;
            if (id) {
              b.selectionDirty = true;
              paint ? b.selection!.add(id) : b.selection!.delete(id);
            }
            setters.get(j)?.(paint, false);
          }
          renderTree();
          lastPaint = i;
        }
      };
      row.onpointerup = () => (paint = null);
      check.onchange = () => set(check.checked);
      check.oncontextmenu = (e) => {
        if (!r.id) return;
        e.preventDefault();
        const revision = b.revision;
        void (async () => {
          const items = await Promise.all(
            [true, false].map((above) =>
              MenuItem.new({
                text: above
                  ? "Check this and all above"
                  : "Uncheck this and all below",
                action: () => {
                  if (
                    active !== b ||
                    b.revision !== revision ||
                    b.rows !== rows
                  )
                    return;
                  for (const entry of rows.slice(
                    above ? 0 : i,
                    above ? i + 1 : rows.length,
                  ))
                    if (entry.id) {
                      b.selectionDirty = true;
                      above
                        ? b.selection!.add(entry.id)
                        : b.selection!.delete(entry.id);
                    }
                  void renderStage();
                  renderTree();
                },
              }),
            ),
          );
          await (await Menu.new({ items })).popup();
        })().catch(fail);
      };
      return row;
    },
    (index) => {
      const i = displayed[index];
      if (i !== null) setters.delete(i);
    },
  );
}
async function stage() {
  if (operationBusy || !active) return;
  busy("Staging…");
  try {
    if (refreshFlight) await refreshFlight;
    const b = active;
    if (b.selectionInvalid)
      throw Error("Buffer changed; review the selection again before staging");
    await loadStage(b);
    if (b.selectionInvalid)
      throw Error("Git staging changed; review the selection again");
    await invoke("stage_selected", {
      selection: selectionFor(b),
      index: b.index,
    });
    b.selectionDirty = false;
    b.selection = null;
    b.source = null;
    try {
      repo = await invoke<Repo>("refresh");
      for (const buffer of buffers.values())
        if (buffer.index) buffer.index = repo.index;
      if (mode() === "stage" && active === b) await renderStage();
    } catch (error) {
      renderTree();
      status(`Staged ${b.path}. Refresh failed: ${error}`);
      return;
    }
    renderTree();
    status(`Staged selected lines in ${b.path}`);
  } finally {
    busy(null);
  }
}
async function commit() {
  if (operationBusy || !repo) return;
  busy("Committing…");
  try {
    if (refreshFlight) await refreshFlight;
    const message =
      $<HTMLInputElement>("#summary").value +
      "\n\n" +
      $<HTMLTextAreaElement>("#body").value;
    if (!$<HTMLInputElement>("#summary").value.trim())
      throw Error("Enter a commit summary");
    const paths = new Set([
      ...repo.staged,
      ...[...buffers.values()]
        .filter((b) => b.selectionDirty || b.selectionInvalid)
        .map((b) => b.path),
    ]);
    const reviewed: BufferState[] = [];
    let index: string | null = null;
    for (const path of paths) {
      const b = await loadBuffer(path);
      if (b.selectionInvalid)
        throw Error(
          `${path}: buffer changed; review the selection again before committing`,
        );
      if (!b.selectionDirty) {
        b.selection = null;
        b.source = null;
      }
      await loadStage(b);
      if (b.selectionInvalid)
        throw Error(`${path}: staging changed; review the selection again`);
      if (index !== null && index !== b.index)
        throw Error("Git staging changed during review; try again");
      index = b.index;
      reviewed.push(b);
    }
    const outcome = await invoke<{
      output: string;
      committed: boolean;
      oid: string | null;
      warning: string | null;
    }>("commit_changes", {
      message,
      selections: reviewed.map(selectionFor),
      index: index ?? repo.index,
    });
    if (!outcome.committed)
      throw Error(outcome.warning ?? "Git did not confirm the commit");
    $<HTMLInputElement>("#summary").value = "";
    $<HTMLTextAreaElement>("#body").value = "";
    for (const b of buffers.values()) {
      b.selection = null;
      b.selectionDirty = false;
      b.selectionInvalid = false;
      b.source = null;
    }
    try {
      await foreground(true);
    } catch (error) {
      const notification = `Committed ${outcome.oid ?? ""}. ${outcome.warning ? outcome.warning + " " : ""}Refresh failed: ${error}`;
      status(notification);
      if (outcome.warning) await choose(notification, ["OK"]);
      return;
    }
    status(outcome.warning ?? outcome.output);
    if (outcome.warning) await choose(outcome.warning, ["OK"]);
  } finally {
    busy(null);
  }
}
function focusedUndo(forward: boolean) {
  const target = document.activeElement;
  if (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement
  ) {
    document.execCommand(forward ? "redo" : "undo");
  } else if (!past.hasFocus) (forward ? redo : undo)(editor);
}
async function action(id: string) {
  if (!menuAvailability()[id]) return;
  switch (id) {
    case "open":
      await pickFolder();
      break;
    case "refresh":
      await foreground();
      break;
    case "save":
      await save();
      break;
    case "save-all":
      await saveAll();
      break;
    case "quit":
      await invoke("request_quit");
      break;
    case "close":
      await closeWindow();
      break;
    case "quick":
      quickOpen();
      break;
    case "undo":
      focusedUndo(false);
      break;
    case "redo":
      focusedUndo(true);
      break;
    case "find":
      showSearch();
      break;
    case "replace":
      showSearch(true);
      break;
    case "find-next":
      searchMove();
      break;
    case "find-prev":
      searchMove(true);
      break;
    case "restore":
      restore();
      break;
    case "wrap":
      wrap = !wrap;
      editor.dispatch({
        effects: wrapConfig.reconfigure(wrap ? EditorView.lineWrapping : []),
      });
      past.dispatch({
        effects: pastWrapConfig.reconfigure(
          wrap ? EditorView.lineWrapping : [],
        ),
      });
      lastPastKey = "";
      updatePast();
      persist();
      await syncMenuState();
      break;
    case "whitespace":
      whitespace = !whitespace;
      persist();
      if (active) applyDiff(active);
      await syncMenuState();
      break;
    case "larger":
      font = Math.min(32, font + 1);
      persist();
      break;
    case "smaller":
      font = Math.max(9, font - 1);
      persist();
      break;
    case "mode":
      setMode(mode() === "edit" ? "stage" : "edit");
      break;
    case "next":
      await navigate(1);
      break;
    case "prev":
      await navigate(-1);
      break;
    case "next-file":
      await navigate(1, true);
      break;
    case "prev-file":
      await navigate(-1, true);
      break;
    case "next-group":
      await navigateLocal(1, false);
      break;
    case "prev-group":
      await navigateLocal(-1, false);
      break;
    case "next-line":
      await navigateLocal(1, true);
      break;
    case "prev-line":
      await navigateLocal(-1, true);
      break;
    case "next-paragraph":
      paragraph(1);
      break;
    case "prev-paragraph":
      paragraph(-1);
      break;
  }
}
for (const id of ["find-next", "find-prev"])
  $("#" + id).onclick = () => void action(id).catch(fail);
$("#edit-mode").onclick = () => setMode("edit");
$("#commit-mode").onclick = () => setMode("stage");
$("#query").oninput = () => {
  updateQuery();
  searchMove();
};
$("#replacement").oninput = updateQuery;
$("#close-search").onclick = closeSearch;
$("#replace-one").onclick = () => {
  updateQuery();
  replaceNext(editor);
};
$("#replace-all").onclick = () => {
  updateQuery();
  replaceAll(editor);
};
for (const id of ["query", "replacement"])
  $("#" + id).onkeydown = (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      searchMove(e.shiftKey);
    }
    if (e.key === "Escape") closeSearch();
  };
$("#quick-query").oninput = () => {
  quickIndex = 0;
  void filterQuick();
};
$("#quick-query").onkeydown = (e) => {
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    quickIndex = Math.max(
      0,
      Math.min(
        quickPaths.length - 1,
        quickIndex + (e.key === "ArrowDown" ? 1 : -1),
      ),
    );
    const el = $(".quick-list"),
      top = quickIndex * 28;
    if (top < el.scrollTop) el.scrollTop = top;
    else if (top + 28 > el.scrollTop + el.clientHeight)
      el.scrollTop = top + 28 - el.clientHeight;
    renderQuick();
  }
  if (e.key === "Enter") {
    e.preventDefault();
    const p = quickMatches()[quickIndex];
    if (p && !quickFiltering && !operationBusy) {
      $<HTMLDialogElement>(".quick").close();
      void activate(p).catch(fail);
    }
  }
};
$("#summary").addEventListener("input", updateCommitButtons);
$("#refresh").onclick = () => void foreground().catch(fail);
$("#stage-selected").onclick = () => void stage().catch(fail);
$("#commit").onclick = () => void commit().catch(fail);
$(".divider").onpointerdown = (e) => {
  const start = e.clientY,
    height = pastHeight;
  document.body.classList.add("resizing");
  $(".divider").setPointerCapture(e.pointerId);
  $(".divider").onpointermove = (e) => {
    pastHeight = Math.max(
      45,
      Math.min($(".main").clientHeight - 100, height + e.clientY - start),
    );
    $(".past").style.height = "";
    document.documentElement.style.setProperty("--past", `${pastHeight}px`);
  };
  $(".divider").onpointercancel = $(".divider").onpointerup = () => {
    document.body.classList.remove("resizing");
    $(".divider").onpointermove = null;
    persist();
  };
};
// Capture before CodeMirror's default bindings (Cmd+] otherwise indents).
document.addEventListener(
  "keydown",
  (e) => {
    if (document.querySelector("dialog[open]")) return;
    if (operationBusy) {
      e.preventDefault();
      e.stopImmediatePropagation();
      return;
    }
    if (!(e.metaKey || e.ctrlKey) || e.isComposing) return;
    if (e.key.toLowerCase() === "r") {
      e.preventDefault();
      void foreground().catch(fail);
      return;
    }
    let command: string | undefined;
    const key = e.key.toLowerCase();
    if (e.code === "BracketRight" || key === "]")
      command = e.shiftKey ? "next-file" : e.altKey ? "next" : "next-line";
    else if (e.code === "BracketLeft" || key === "[")
      command = e.shiftKey ? "prev-file" : e.altKey ? "prev" : "prev-line";
    else if (key === "f") command = e.altKey ? "replace" : "find";
    else if (key === "g") command = e.shiftKey ? "find-prev" : "find-next";
    else if (key === "s") command = e.shiftKey ? "save-all" : "save";
    else if (key === "d") command = "restore";
    else if (key === "t") command = "quick";
    else if (key === "o") command = "open";
    else if (key === "z" && editor.hasFocus)
      command = e.shiftKey ? "redo" : "undo";
    if (command) {
      e.preventDefault();
      e.stopImmediatePropagation();
      void action(command).catch(fail);
    }
  },
  true,
);

document.addEventListener("keydown", (e) => {
  if (operationBusy) return;
  if (e.ctrlKey && !e.metaKey && (e.code === "Comma" || e.code === "Period")) {
    e.preventDefault();
    void action(
      `${e.code === "Period" ? "next" : "prev"}-${e.shiftKey ? "line" : "group"}`,
    ).catch(fail);
    return;
  }
  if (e.key.startsWith("Arrow")) splitUndo = true;
  if (e.key === "Escape" && !$(".search").hidden) closeSearch();
  if (
    e.altKey &&
    !e.metaKey &&
    !e.ctrlKey &&
    (e.key === "ArrowUp" || e.key === "ArrowDown") &&
    editor.hasFocus
  ) {
    e.preventDefault();
    void action(
      e.key === "ArrowDown" ? "next-paragraph" : "prev-paragraph",
    ).catch(fail);
  }
});

const quitCancelledListener = listen<number>(
  "quit-cancelled",
  ({ payload }) => {
    if (quitPending !== payload) return;
    quitPending = null;
    busy(null);
  },
);
const quitRequestListener = listen<number>(
  "request-quit",
  async ({ payload: attempt }) => {
    if (quitPending === attempt) return;
    if (operationBusy) {
      await invoke("quit_response", { approved: false, attempt });
      return;
    }
    quitPending = attempt;
    busy("Waiting for windows to finish closing…");
    try {
      if (refreshFlight) await refreshFlight;
      const approved = await canClose();
      await invoke("quit_response", { approved, attempt });
    } catch (e) {
      await invoke("quit_response", { approved: false, attempt });
      fail(e);
    }
  },
);
void Promise.all([quitCancelledListener, quitRequestListener])
  .then(() => invoke("frontend_ready"))
  .catch(fail);
void win.onFocusChanged(({ payload }) => {
  if (payload) {
    void syncMenuState(true).catch(fail);
    void foreground().catch(fail);
  }
});
void win.onCloseRequested(async (e) => {
  if (operationBusy) {
    e.preventDefault();
    return;
  }
  if (closing) return;
  e.preventDefault();
  await closeWindow().catch(fail);
});
async function closeWindow() {
  if (operationBusy || closing) return;
  busy("Closing…");
  try {
    if (refreshFlight) await refreshFlight;
    if (await canClose()) {
      closing = true;
      try {
        await win.destroy();
      } catch (error) {
        closing = false;
        throw error;
      }
    }
  } finally {
    if (!closing) busy(null);
  }
}
function menuAvailability(): Record<string, boolean> {
  repoMembership();
  const ready = !operationBusy && !quitPending && !closing;
  const editing = ready && !!active && mode() === "edit";
  const field =
    document.activeElement instanceof HTMLInputElement ||
    document.activeElement instanceof HTMLTextAreaElement;
  const fieldCommand = (command: string) => {
    try {
      return field && document.queryCommandEnabled(command);
    } catch {
      return false;
    }
  };
  const localChanges =
    editing &&
    active!.changes.some((c) =>
      visible(c, active!.base, editor.state.doc, whitespace),
    );
  const otherFiles =
    !!repo &&
    ([...changedPaths].some((p) => p !== active?.path) ||
      [...buffers.values()].some((b) => b !== active && dirty(b)));
  const c =
    active && changeAt(active.changes, editor.state.selection.main.head);
  const pos = editor.state.selection.main.head;
  return {
    open: ready,
    quit: ready,
    close: ready,
    save: ready && !!active && dirty(active),
    "save-all": ready && [...buffers.values()].some(dirty),
    refresh: ready && !!repo && !refreshing,
    undo:
      ready &&
      (field
        ? fieldCommand("undo")
        : editing && editor.hasFocus && undoDepth(editor.state) > 0),
    redo:
      ready &&
      (field
        ? fieldCommand("redo")
        : editing && editor.hasFocus && redoDepth(editor.state) > 0),
    find: editing,
    replace: editing,
    "find-next": editing,
    "find-prev": editing,
    restore:
      editing &&
      !field &&
      (!!c ||
        selectedChanges().length > 0 ||
        (past.hasFocus &&
          active!.changes.some(
            (c) =>
              c.a <= past.state.selection.main.head &&
              past.state.selection.main.head <= c.aEnd,
          ))),
    wrap: editing,
    whitespace: editing,
    larger: editing && font < 32,
    smaller: editing && font > 9,
    mode: ready && !!repo?.gitRoot,
    quick: ready && !!repo?.files.length,
    next: editing && (localChanges || otherFiles),
    prev: editing && (localChanges || otherFiles),
    "next-file": ready && !!repo && otherFiles,
    "prev-file": ready && !!repo && otherFiles,
    "next-group": localChanges,
    "prev-group": localChanges,
    "next-line": localChanges,
    "prev-line": localChanges,
    "next-paragraph": editing && pos < editor.state.doc.length,
    "prev-paragraph": editing && pos > 0,
  };
}
let lastMenuState = "";
async function syncMenuState(force = false) {
  const state = { enabled: menuAvailability(), wrap, whitespace };
  const key = JSON.stringify(state);
  if (!force && key === lastMenuState) return;
  lastMenuState = key;
  try {
    await invoke("menu_state", state);
  } catch (e) {
    lastMenuState = "";
    throw e;
  }
}
let menuSyncQueued = false;
function scheduleMenuState() {
  if (menuSyncQueued) return;
  menuSyncQueued = true;
  queueMicrotask(() => {
    menuSyncQueued = false;
    void syncMenuState().catch(fail);
  });
}
for (const name of ["focusin", "focusout", "input", "selectionchange"]) {
  document.addEventListener(name, scheduleMenuState);
}

void listen<string>("menu-action", ({ payload }) => {
  void action(payload)
    .then(() => syncMenuState())
    .catch(fail);
});
void syncMenuState().catch(fail);

let sidebarWidth = Math.max(
  150,
  Math.min(prefs.sidebarWidth, window.innerWidth - 150),
);
document.documentElement.style.setProperty("--sidebar", `${sidebarWidth}px`);
$(".sidebar-divider").onpointerdown = (e) => {
  const x = e.clientX,
    width = sidebarWidth;
  const divider = $(".sidebar-divider");
  divider.setPointerCapture(e.pointerId);
  divider.onpointermove = (e) => {
    sidebarWidth = Math.max(
      150,
      Math.min(550, window.innerWidth - 150, width + e.clientX - x),
    );
    document.documentElement.style.setProperty(
      "--sidebar",
      `${sidebarWidth}px`,
    );
  };
  divider.onpointercancel = divider.onpointerup = () => {
    divider.onpointermove = null;
    try {
      localStorage.setItem("sidebarWidth", String(sidebarWidth));
    } catch {
      /* Storage may be unavailable. */
    }
  };
};

window.addEventListener("storage", (event) => {
  if (
    event.key !== "preferences" &&
    event.key !== "sidebarWidth" &&
    event.key !== null
  )
    return;
  const next = readPreferences(localStorage);
  wrap = next.wrap;
  whitespace = next.whitespace;
  font = next.font;
  pastHeight = Math.max(
    45,
    Math.min(next.pastHeight, Math.max(45, $(".main").clientHeight - 100)),
  );
  sidebarWidth = Math.max(
    150,
    Math.min(next.sidebarWidth, window.innerWidth - 150),
  );
  storedPreferences = { wrap, whitespace, font, pastHeight };
  document.documentElement.style.setProperty("--font", `${font}px`);
  document.documentElement.style.setProperty("--past", `${pastHeight}px`);
  document.documentElement.style.setProperty("--sidebar", `${sidebarWidth}px`);
  editor.dispatch({
    effects: wrapConfig.reconfigure(wrap ? EditorView.lineWrapping : []),
  });
  past.dispatch({
    effects: pastWrapConfig.reconfigure(wrap ? EditorView.lineWrapping : []),
  });
  lastPastKey = "";
  if (active) applyDiff(active);
  if (mode() === "stage") void renderStage().catch(fail);
  void syncMenuState().catch(fail);
});
window.addEventListener("resize", () => {
  pastHeight = Math.max(
    45,
    Math.min(pastHeight, Math.max(45, $(".main").clientHeight - 100)),
  );
  sidebarWidth = Math.max(150, Math.min(sidebarWidth, window.innerWidth - 150));
  document.documentElement.style.setProperty("--past", `${pastHeight}px`);
  document.documentElement.style.setProperty("--sidebar", `${sidebarWidth}px`);
});

const initialFolder = new URLSearchParams(window.location.search).get("folder");
if (initialFolder) void openFolder(initialFolder, true).catch(fail);

if (new URLSearchParams(window.location.search).get("command") === "open")
  void pickFolder().catch(fail);

// Read actual editor geometry so search rows, the divider, font size and status
// bar are included in the resize grid's offset. Width remains freely resizable.
let lastResizeGrid = "";
const resizeGridObserver = new ResizeObserver(() => {
  editor.requestMeasure({
    key: resizeGridObserver,
    read: (view) => {
      const height = view.scrollDOM.clientHeight;
      const enabled = height > 0 && !$(".editor-stack").hidden;
      const line = enabled ? view.defaultLineHeight : 1;
      return {
        line,
        height,
        delta: enabled ? Math.round(height / line) * line - height : 0,
      };
    },
    write: ({ line, height, delta }) => {
      const key = `${line}:${height}:${delta}`;
      if (lastResizeGrid === key) return;
      lastResizeGrid = key;
      void invoke("resize_grid", { line, delta }).catch(console.error);
    },
  });
});
resizeGridObserver.observe(editor.scrollDOM);
resizeGridObserver.observe(editor.contentDOM);
