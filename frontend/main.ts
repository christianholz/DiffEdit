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
  ChangeSet,
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
  Diff,
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
const buffers = new Map<string, BufferState>(),
  expanded = new Set<string>();
const prefs = JSON.parse(localStorage.getItem("preferences") || "{}");
let wrap: boolean = prefs.wrap ?? true,
  whitespace: boolean = prefs.whitespace ?? false,
  font: number = prefs.font ?? 13;
let pastHeight: number = Math.max(45, prefs.pastHeight ?? 5 * font * 1.55 + 16);
let quickPaths: string[] = [],
  quickIndex = 0,
  opening = 0;
interface BufferState extends Document {
  state: EditorState;
  changes: Change[];
  pending: ChangeSet | null;
  flight: Promise<void> | null;
  error: string | null;
  scroll: number;
  selection: Set<string> | null;
  rows: StageRow[];
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
let quitPending = false;
let operationBusy = false;
const editor = new EditorView({
  parent: $(".now"),
  state: makeState(""),
  dispatchTransactions: (trs) => {
    if ((quitPending || operationBusy) && trs.some((tr) => tr.docChanged))
      return;
    const b = active;
    editor.update(trs);
    if (!b) return;
    for (const tr of trs) {
      if (tr.docChanged) {
        b.revision++;
        b.pending = b.pending ? b.pending.compose(tr.changes) : tr.changes;
        b.changes = previewChanges(b.changes, b.base, tr);
        b.state = editor.state;
        b.text = "";
        void pump(b);
        updateTitle();
        updateFileIndicator(b);
      } else if (tr.selection) splitUndo = true;
    }
    if (trs.some((tr) => tr.docChanged)) {
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
      editorStyleNonce(),
      EditorState.lineSeparator.of("\n"),
      lineNumbers(),
      decorations,
      EditorView.updateListener.of((u) => {
        if (u.selectionSet && u.view.hasFocus) reflectPastSelection();
      }),
      EditorView.domEventHandlers({
        contextmenu(e, v) {
          if (!active) return false;
          const pos = v.posAtCoords({ x: e.clientX, y: e.clientY });
          const c =
            pos === null
              ? undefined
              : active.changes.find((c) => c.a <= pos && pos < c.aEnd);
          if (!c) return false;
          e.preventDefault();
          void pastRestoreMenu(c);
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
function busy(s: string | null) {
  operationBusy = !!s;
  $(".sidebar").inert = !!s;
  $(".editor-stack").inert = !!s;
  $(".stage").inert = !!s;
  $(".search").inert = !!s;
  $(".overlay").hidden = !s;
  $("#busy-message").textContent = s || "";
  scheduleMenuState();
}
function choose(message: string, choices: string[]): Promise<string> {
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
function persist() {
  localStorage.setItem(
    "preferences",
    JSON.stringify({ wrap, whitespace, font, pastHeight }),
  );
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
    `Ln ${l.number}, Col ${p - l.from + 1}  ·  ${active.changes.length} changes${dirty(active) ? "  ·  Unsaved" : ""}`,
  );
}
function updateFileIndicator(b: BufferState) {
  const el = Array.from(
    document.querySelectorAll<HTMLElement>("[data-path]"),
  ).find((el) => el.dataset.path === b.path);
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
  if (!routed) {
    const selected = await invoke<string | null>("route_folder", {
      root,
      reuse: !repo,
    });
    if (selected === null) return;
    root = selected;
    if (repo?.root === root) return;
  }
  if (buffers.size && !(await canClose())) return;
  busy("Opening folder…");
  try {
    for (const b of buffers.values()) await flush(b);
    repo = await invoke<Repo>("open_folder", { root });
    buffers.clear();
    active = null;
    editor.setState(makeState(""));
    $(".editor-stack").hidden = true;
    $(".stage").hidden = true;
    $(".placeholder").hidden = false;
    $<HTMLButtonElement>("#edit-mode").disabled = false;
    $<HTMLButtonElement>("#commit-mode").disabled = !repo.gitRoot;

    $("#branch").textContent = `Branch: ${repo.branch}`;
    expanded.clear();
    await invoke("remember_folder", {
      root: repo.root,
    }).catch(console.error);
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
function renderTree() {
  const tree = $(".tree");
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
    repo!.changed.includes(p) || !!(buffers.has(p) && dirty(buffers.get(p)!));
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
    dot.textContent = repo.changed.includes(path) ? "●" : "";
    const unsaved = document.createElement("span");
    unsaved.className = "dirty";
    unsaved.textContent =
      buffers.has(path) && dirty(buffers.get(path)!) ? "●" : "";
    if (mode() === "stage") {
      const check = document.createElement("input");
      check.type = "checkbox";
      const b = buffers.get(path);
      const ids = b?.rows.flatMap((r) => (r.id ? [r.id] : [])) || [];
      const count = ids.filter((id) => b?.selection?.has(id)).length;
      check.checked =
        b?.selection === null || !b
          ? repo.changed.includes(path)
          : ids.length > 0 && count === ids.length;
      check.indeterminate = count > 0 && count < ids.length;
      check.onclick = (e) => {
        e.stopPropagation();
        const all = check.checked;
        void (async () => {
          await activate(path);
          await renderStage();
          if (!active || active.path !== path) return;
          active.selection = new Set(
            all ? active.rows.flatMap((r) => (r.id ? [r.id] : [])) : [],
          );
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
  let b = buffers.get(path);
  if (!b) {
    status("Opening…");
    const d = await invoke<Document>("open_document", { path });
    b = {
      ...d,
      state: makeState(d.text),
      changes: [],
      pending: null,
      flight: null,
      error: null,
      scroll: 0,
      selection: null,
      rows: [],
      micros: 0,
      revision: 0,
      diskDoc: Text.of((d.disk ?? "").split("\n")),
      diffEpoch: 0,
    };
    buffers.set(path, b);
    const u = await invoke<{ version: number; diff: Diff }>("document_diff", {
      path,
    });
    b.changes = u.diff.changes;
    b.micros = u.diff.micros;
  }
  if (id !== opening) return;
  past.contentDOM.blur();
  active = b;
  splitUndo = true;
  lastInputClass = "";
  editor.setState(b.state);
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
async function pump(b: BufferState): Promise<void> {
  if (b.flight) return b.flight;
  if (!b.pending) return;
  const changes = b.pending;
  b.pending = null;
  const edits: { from: number; to: number; insert: string }[] = [];
  changes.iterChanges((from, to, _f, _t, text) =>
    edits.push({ from, to, insert: text.toString() }),
  );
  const version = b.version + 1,
    start = performance.now();
  b.flight = (async () => {
    try {
      const result = await invoke<{ version: number; diff: Diff }>(
        "edit_document",
        { path: b.path, version, edits },
      );
      b.version = result.version;
      b.error = null;
      if (!b.pending) {
        b.changes = result.diff.changes;
        b.diffEpoch++;
        b.micros = result.diff.micros;
        if (active === b) {
          applyDiff(b);
          $(".timing").textContent =
            `diff ${(b.micros / 1000).toFixed(1)} ms · round trip ${(performance.now() - start).toFixed(1)} ms`;
        }
      }
    } catch (e) {
      b.error = String(e);
      fail(e);
    } finally {
      b.flight = null;
    }
  })();
  await b.flight;
  if (b.pending && !b.error) await pump(b);
}
async function flush(b: BufferState) {
  while (b.flight || b.pending) {
    await pump(b);
    if (b.error) throw Error(b.error);
  }
  if (b.error) throw Error(b.error);
}
function marks(
  changes: Change[],
  base: string,
  current: Text,
  pastSide = false,
): DecorationSet {
  const list = [];
  for (const c of changes) {
    if (
      !whitespace &&
      !/\S/u.test(base.slice(c.a, c.aEnd) + current.sliceString(c.b, c.bEnd))
    )
      continue;
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
  updateOverview();
  updateStatus();
  void updateRestoreEnabled();
}
let lastPastKey = "";
let pastScrollFocus = "";
let lastPastBase = "";
function updatePast() {
  const b = active;
  if (!b || past.hasFocus) return;
  const pos = editor.state.selection.main.head,
    c = changeAt(b.changes, pos);
  let target = basePosition(b.changes, pos),
    focus: [number, number] = wordRange(b.base, target),
    deleted = false,
    green = false;
  if (
    c &&
    (whitespace ||
      /\S/u.test(
        b.base.slice(c.a, c.aEnd) + editor.state.sliceDoc(c.b, c.bEnd),
      ))
  ) {
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
    b.diffEpoch,
    b.revision,
    focus,
    green,
    whitespace,
    editor.state.selection.toJSON(),
  ]);
  if (key === lastPastKey) return;
  const baseChanged = past.state.doc.toString() !== b.base;
  // Derive decorations from this buffer, never from the previously active file.
  const d = marks(b.changes, b.base, editor.state.doc, true);
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
                    Math.min(...ranges.map((r) => r[0])),
                    Math.max(...ranges.map((r) => r[1])),
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
function updateOverview() {
  const el = $(".overview");
  el.replaceChildren();
  if (!active) return;
  const height = Math.max(1, editor.contentHeight);
  const current = editor.state.doc.toString();
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
  return active.changes.filter((c) =>
    editor.state.selection.ranges.some(
      (r) =>
        !r.empty &&
        (c.b === c.bEnd
          ? c.b >= r.from && c.b < r.to
          : c.b < r.to && c.bEnd > r.from),
    ),
  );
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
  c ??= changeAt(active.changes, editor.state.selection.main.head);
  if (!c || c.a === c.aEnd || c.b === c.bEnd) return;
  restoreChanges([c]);
}
async function restoreMenu(changes: Change[], selection = false) {
  if (!active) return;
  const path = active.path,
    revision = active.revision;
  const item = await MenuItem.new({
    text: selection
      ? `Restore ${changes.length} ${changes.length === 1 ? "change" : "changes"}`
      : `Restore '${active.base.slice(changes[0].a, changes[0].aEnd)}'`,
    action: () => {
      if (active?.path === path && active.revision === revision)
        restoreChanges(changes);
    },
  });
  const menu = await Menu.new({ items: [item] });
  await menu.popup();
}
async function pastRestoreMenu(c: Change) {
  if (!active) return;
  const path = active.path,
    revision = active.revision;
  const item = await MenuItem.new({
    text: c.b === c.bEnd ? "Keep" : "Restore",
    action: () => {
      if (active?.path === path && active.revision === revision)
        restoreChanges([c]);
    },
  });
  await (await Menu.new({ items: [item] })).popup();
}
let restoreEnabled = false;
async function updateRestoreEnabled() {
  const c =
    active && changeAt(active.changes, editor.state.selection.main.head);
  const enabled = !!c && c.aEnd > c.a && c.bEnd > c.b;
  if (enabled !== restoreEnabled) {
    restoreEnabled = enabled;
    await syncMenuState();
  }
}
async function save(b = active) {
  if (!b) return;
  await flush(b);
  try {
    const d = await invoke<Document>("save_document", { path: b.path });
    b.disk = d.disk;
    b.diskDoc = Text.of((d.disk ?? "").split("\n"));
    if (active === b) {
      updateTitle();
      updateStatus();
    }
    updateFileIndicator(b);
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
  await flush(b);
  const d = await invoke<Document>("resolve_document", {
    path: b.path,
    reload,
  });
  b.disk = d.disk;
  b.diskDoc = Text.of((d.disk ?? "").split("\n"));
  b.base = d.base;
  b.version = d.version;
  if (reload) {
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
  await refreshDiff(b);
  updateTitle();
  renderTree();
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
async function refreshDiff(b: BufferState) {
  await flush(b);
  const revision = b.revision;
  const result = await invoke<{ version: number; diff: Diff }>(
    "document_diff",
    { path: b.path },
  );
  if (result.version === b.version && revision === b.revision && !b.pending) {
    b.changes = result.diff.changes;
    b.diffEpoch++;
    b.micros = result.diff.micros;
    if (active === b) applyDiff(b);
  }
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
async function performForeground() {
  if (!repo || refreshing || closing) return;
  refreshing = true;
  try {
    repo = await invoke<Repo>("refresh");
    $("#branch").textContent = `Branch: ${repo.branch}`;
    for (const b of buffers.values()) {
      await flush(b);
      const d = await invoke<Document>("inspect_document", { path: b.path });
      const baseChanged = b.base !== d.base;
      b.base = d.base;
      if (d.disk !== b.disk) {
        if (dirty(b)) {
          const c = await choose(
            `${b.path} was changed or deleted outside DiffEdit.`,
            ["Cancel", "Keep Buffer", "Reload"],
          );
          if (c !== "Cancel") await resolve(b, c === "Reload");
        } else await resolve(b, true);
      } else if (baseChanged) await refreshDiff(b);
    }
    renderTree();
  } catch (e) {
    fail(e);
  } finally {
    refreshing = false;
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
  if (!repo) return;
  const paths = repo.files.filter(
    (p) =>
      repo!.changed.includes(p) ||
      (buffers.has(p) && buffers.get(p)!.changes.length),
  );
  if (!file && active) {
    const pos = editor.state.selection.main.head;
    const candidates = active.changes.filter((c) =>
      direction > 0 ? c.b > pos : c.b < pos,
    );
    const c = direction > 0 ? candidates[0] : candidates.at(-1);
    if (c) {
      jump(c.b);
      return;
    }
  }
  if (!paths.length) return;
  const i = active ? paths.indexOf(active.path) : -1;
  await activate(paths[(i + direction + paths.length) % paths.length]);
  const c = direction > 0 ? active?.changes[0] : active?.changes.at(-1);
  if (c) jump(c.b);
}
async function navigateLocal(direction: number, byLine: boolean) {
  if (!active) return;
  await flush(active);
  const lines = new Set<number>();
  const currentText = editor.state.doc.toString();
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
  $(".commit-box").hidden = !staging;
  $("#branch").hidden = !staging;
  renderTree();
  $(".editor-stack").hidden = !active || staging;
  $(".stage").hidden = !active || !staging;
  if (active && staging) void renderStage().catch(fail);
  if (!staging) {
    updatePast();
    // Editors may have been initialized or switched while their container was hidden.
    editor.requestMeasure();
    past.requestMeasure();
  }
}
async function renderStage() {
  const b = active;
  if (!b) return;
  await flush(b);
  const revision = b.revision;
  const rows = await invoke<StageRow[]>("stage_rows", { path: b.path });
  if (active !== b || b.revision !== revision) return;
  const previouslyExcluded = new Set(
    b.rows.flatMap((r) => (r.id && !b.selection?.has(r.id) ? [r.id] : [])),
  );
  b.rows = rows;
  const available = rows.flatMap((r) => (r.id ? [r.id] : []));
  if (b.selection === null) b.selection = new Set(available);
  else
    b.selection = new Set(
      available.filter((id) => !previouslyExcluded.has(id)),
    );
  const el = $(".stage");
  el.replaceChildren();
  let paint: boolean | null = null;
  let lastPaint = -1;
  const setters = new Map<number, (v: boolean, render?: boolean) => void>();
  let skip = false;
  rows.forEach((r, i) => {
    if (
      r.kind === "equal" &&
      !rows.slice(Math.max(0, i - 3), i + 4).some((x) => x.kind !== "equal")
    ) {
      if (!skip) {
        const gap = document.createElement("div");
        gap.textContent = "             ⋯";
        el.append(gap);
        skip = true;
      }
      return;
    }
    skip = false;
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
      v ? b.selection!.add(r.id) : b.selection!.delete(r.id);
      check.checked = v;
      row.classList.toggle("off", !v);
      if (render) renderTree();
    };
    setters.set(i, set);
    row.onpointerdown = (e) => {
      if (!r.id || e.button !== 0) return;
      e.preventDefault();
      lastPaint = i;
      paint = !check.checked;
      set(paint);
    };
    row.onpointerenter = (e) => {
      if (e.buttons === 1 && paint !== null) {
        for (let j = Math.min(lastPaint, i); j <= Math.max(lastPaint, i); j++)
          setters.get(j)?.(paint, false);
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
                if (active !== b || b.revision !== revision) return;
                for (const entry of rows.slice(
                  above ? 0 : i,
                  above ? i + 1 : rows.length,
                ))
                  if (entry.id) {
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
    el.append(row);
  });
}
async function stage() {
  if (operationBusy || !active) return;
  const b = active;
  await flush(b);
  await invoke("stage_selected", {
    path: b.path,
    selected: [...(b.selection || [])],
    version: b.version,
  });
  repo = await invoke<Repo>("refresh");
  renderTree();
  status(`Staged selected lines in ${b.path}`);
}
async function commit() {
  if (operationBusy || !repo) return;
  busy("Committing…");
  try {
    if (refreshFlight) await refreshFlight;
    for (const b of buffers.values()) await flush(b);
    const message =
      $<HTMLInputElement>("#summary").value +
      "\n\n" +
      $<HTMLTextAreaElement>("#body").value;
    if (active) await renderStage();
    const selected = active
      ? {
          path: active.path,
          version: active.version,
          selected: [
            ...(active.selection ??
              new Set(active.rows.flatMap((r) => (r.id ? [r.id] : [])))),
          ],
        }
      : null;
    const output = await invoke<string>("commit_changes", {
      message,
      selection: selected,
    });
    $<HTMLInputElement>("#summary").value = "";
    $<HTMLTextAreaElement>("#body").value = "";
    for (const b of buffers.values()) b.selection = null;
    await foreground(true);
    if (mode() === "stage") await renderStage();
    status(output);
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
      if (await canClose()) {
        closing = true;
        await win.destroy();
      }
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
$("#stage-selected").onclick = () => void stage().catch(fail);
$("#commit").onclick = () => void commit().catch(fail);
$(".divider").onpointerdown = (e) => {
  const start = e.clientY,
    height = pastHeight;
  document.body.classList.add("resizing");
  $(".divider").setPointerCapture(e.pointerId);
  $(".divider").onpointermove = (e) => {
    pastHeight = Math.max(
      35,
      Math.min($(".main").clientHeight - 100, height + e.clientY - start),
    );
    $(".past").style.height = "";
    document.documentElement.style.setProperty("--past", `${pastHeight}px`);
  };
  $(".divider").onpointerup = () => {
    document.body.classList.remove("resizing");
    $(".divider").onpointermove = null;
    persist();
  };
};
// Capture before CodeMirror's default bindings (Cmd+] otherwise indents).
document.addEventListener(
  "keydown",
  (e) => {
    if (operationBusy) {
      e.preventDefault();
      e.stopImmediatePropagation();
      return;
    }
    if (!(e.metaKey || e.ctrlKey) || e.isComposing) return;
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

void listen("quit-cancelled", () => {
  if (!quitPending) return;
  quitPending = false;
  busy(null);
});
void listen("request-quit", async () => {
  if (operationBusy) {
    await invoke("quit_response", { approved: false });
    return;
  }
  quitPending = true;
  busy("Waiting for windows to finish closing…");
  try {
    await invoke("quit_response", { approved: await canClose() });
  } catch (e) {
    await invoke("quit_response", { approved: false });
    fail(e);
  }
});
void win.onFocusChanged(({ payload }) => {
  if (payload) {
    void syncMenuState(true).catch(fail);
    void foreground();
  }
});
void win.onCloseRequested(async (e) => {
  if (operationBusy) {
    e.preventDefault();
    return;
  }
  if (closing) return;
  e.preventDefault();
  try {
    if (await canClose()) {
      closing = true;
      await win.destroy();
    }
  } catch (e) {
    fail(e);
  }
});
function menuAvailability(): Record<string, boolean> {
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
    active!.changes.some(
      (c) =>
        whitespace ||
        /\S/u.test(
          active!.base.slice(c.a, c.aEnd) +
            editor.state.doc.sliceString(c.b, c.bEnd),
        ),
    );
  const otherFiles =
    !!repo &&
    repo.files.some(
      (p) =>
        p !== active?.path &&
        (repo!.changed.includes(p) ||
          (buffers.has(p) && dirty(buffers.get(p)!))),
    );
  const c =
    active && changeAt(active.changes, editor.state.selection.main.head);
  const pos = editor.state.selection.main.head;
  return {
    open: ready,
    quit: ready,
    close: ready,
    save: ready && !!active && dirty(active),
    "save-all": ready && [...buffers.values()].some(dirty),
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
      !past.hasFocus &&
      !!c &&
      c.aEnd > c.a &&
      c.bEnd > c.b,
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

let sidebarWidth = Number(localStorage.getItem("sidebarWidth")) || 240;
document.documentElement.style.setProperty("--sidebar", `${sidebarWidth}px`);
$(".sidebar-divider").onpointerdown = (e) => {
  const x = e.clientX,
    width = sidebarWidth;
  const divider = $(".sidebar-divider");
  divider.setPointerCapture(e.pointerId);
  divider.onpointermove = (e) => {
    sidebarWidth = Math.max(150, Math.min(550, width + e.clientX - x));
    document.documentElement.style.setProperty(
      "--sidebar",
      `${sidebarWidth}px`,
    );
  };
  divider.onpointerup = () => {
    divider.onpointermove = null;
    localStorage.setItem("sidebarWidth", String(sidebarWidth));
  };
};

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
