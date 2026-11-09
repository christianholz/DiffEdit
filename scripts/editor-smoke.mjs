// Headless transaction/lifecycle check; this does not simulate native window layout.
import { Window } from "happy-dom";
import { build } from "esbuild";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import { emit } from "@tauri-apps/api/event";
import { Transaction } from "@codemirror/state";
const dom = new Window({ url: "http://tauri.localhost" });
for (const name of [
  "window",
  "document",
  "navigator",
  "localStorage",
  "MutationObserver",
  "ResizeObserver",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLDialogElement",
  "Node",
  "NodeFilter",
  "DOMRect",
  "Range",
  "KeyboardEvent",
  "Event",
])
  Object.defineProperty(globalThis, name, {
    value: name === "window" ? dom : dom[name],
    configurable: true,
  });
globalThis.getComputedStyle = dom.getComputedStyle.bind(dom);
globalThis.requestAnimationFrame = dom.requestAnimationFrame.bind(dom);
globalThis.cancelAnimationFrame = dom.cancelAnimationFrame.bind(dom);
document.body.innerHTML = (await readFile("frontend/index.html", "utf8"))
  .match(/<body>([\s\S]*?)<\/body>/)[1]
  .replace(/<script[\s\S]*?<\/script>/g, "");
let commitCalls = 0,
  commitSelection;
let holdCommit;
let inspectionGate = null;
let startupFolder = null;
let startupReads = 0;
let stageRowCount = 2;
let divergedStage = false;
let failNextRefresh = false,
  failInspections = false;
const inspectedPaths = [];
const releasedPaths = [];
let text = "Original paragraph.\nSecond line.\n",
  base = text,
  version = 0,
  disk = text,
  id = 0;
const menus = new Map();
const longBase = "Unchanged paragraph.\n".repeat(420) + "Removed ending.\n";
const longText = "Unchanged paragraph.\n".repeat(420) + "New ending.\n";
const switchDocuments = {
  "long.tex": {
    path: "long.tex",
    base: longBase,
    text: longText,
    disk: longText,
    version: 0,
    head: "h",
    baseExists: true,
  },
  "short.tex": {
    path: "short.tex",
    base: "Old.\n",
    text: "New.\n",
    disk: "New.\n",
    version: 0,
    head: "h",
    baseExists: true,
  },
};
function diff() {
  let left = 0,
    right = 0;
  while (left < base.length && left < text.length && base[left] === text[left])
    left++;
  while (
    right < base.length - left &&
    right < text.length - left &&
    base[base.length - 1 - right] === text[text.length - 1 - right]
  )
    right++;
  return {
    version,
    head: "h",
    diff: {
      changes:
        text === base
          ? []
          : [
              {
                a: left,
                aEnd: base.length - right,
                b: left,
                bEnd: text.length - right,
              },
            ],
      micros: 100,
    },
  };
}
mockWindows("main");
mockIPC(
  async (cmd, args = {}) => {
    if (cmd === "plugin:menu|new") {
      const item = [++id, args.options?.id ?? String(id), args.kind];
      menus.set(item[1], item);
      return item.slice(0, 2);
    }
    if (cmd === "plugin:menu|get")
      return menus.get(args.id) || [0, args.id, "MenuItem"];
    if (cmd.startsWith("plugin:")) return null;
    if (cmd === "commit_changes") {
      commitCalls++;
      commitSelection = args.selections;
      await new Promise((resolve) => {
        holdCommit = resolve;
      });
      return {
        output: "Committed",
        committed: true,
        oid: "new-head",
        warning: null,
      };
    }
    if (cmd === "inspect_document") {
      inspectedPaths.push(args.path);
      if (failInspections) throw Error(`Cannot inspect ${args.path}`);
      const snapshot = {
        base,
        disk,
        version,
        head: "h",
        baseExists: true,
        diff: diff().diff,
      };
      const gate = inspectionGate;
      inspectionGate = null;
      if (gate) await gate;
      return snapshot;
    }
    if (cmd === "resolve_document") {
      assert.equal(args.version, version);
      if (args.reload) {
        text = disk ?? "";
        version++;
      }
      return {
        document: {
          path: args.path,
          text,
          base,
          disk,
          version,
          head: "h",
          baseExists: true,
        },
        diff: diff().diff,
      };
    }
    if (cmd === "take_startup_folder") {
      startupReads++;
      const path = startupFolder;
      startupFolder = null;
      return path;
    }
    if (cmd === "route_folder") return args.root;
    if (cmd === "quick_matches")
      return Array.from({ length: 300 }, (_, i) => `file-${i}.tex`);
    if (cmd === "refresh" && failNextRefresh) {
      failNextRefresh = false;
      throw Error("Refresh unavailable");
    }
    if (cmd === "open_folder" || cmd === "refresh")
      return {
        root: "/fixture",
        gitRoot: "/fixture",
        prefix: "",
        branch: "main",
        files: ["fixture.tex", "unchanged.txt"],
        changed: ["fixture.tex"],
        staged: ["fixture.tex"],
        head: "h",
        index: "index",
      };
    if (switchDocuments[args.path]) {
      const doc = switchDocuments[args.path];
      if (cmd === "open_document") return doc;
      if (cmd === "document_diff") {
        const start =
          args.path === "long.tex"
            ? "Unchanged paragraph.\n".repeat(420).length
            : 0;
        return {
          version: 0,
          head: "h",
          baseExists: true,
          diff: {
            micros: 1,
            changes: [
              {
                a: start,
                aEnd: doc.base.length - 1,
                b: start,
                bEnd: doc.text.length - 1,
              },
            ],
          },
        };
      }
    }
    if (cmd === "open_document")
      return {
        path: "fixture.tex",
        text,
        base,
        disk,
        version,
        head: "h",
        baseExists: true,
      };
    if (cmd === "document_diff") return diff();
    if (cmd === "edit_document") {
      assert.equal(args.version, version + 1);
      for (const e of args.edits.toReversed())
        text = text.slice(0, e.from) + e.insert + text.slice(e.to);
      version++;
      return diff();
    }
    if (cmd === "save_document") {
      disk = text;
      return {
        path: "fixture.tex",
        text,
        base,
        disk,
        version,
        head: "h",
        baseExists: true,
      };
    }
    if (
      cmd === "frontend_ready" ||
      cmd === "menu_state" ||
      cmd === "remember_folder"
    )
      return null;
    if (cmd === "document_path" || cmd === "resize_grid") return null;
    if (cmd === "stage_selected") return null;
    if (cmd === "release_document") {
      releasedPaths.push(args.path);
      return null;
    }
    if (cmd === "stage_rows")
      return {
        source: args.source ?? (divergedStage ? "index" : "buffer"),
        version,
        head: "h",
        index: "index",
        selected: ["first", "second"],
        rows:
          stageRowCount > 2
            ? Array.from({ length: stageRowCount }, (_, i) => ({
                id: `line:${i}`,
                kind: "insert",
                oldLine: null,
                newLine: i + 1,
                text: "line\n",
              }))
            : [
                {
                  id: "first",
                  kind: "insert",
                  oldLine: null,
                  newLine: 3,
                  text: "wo",
                },
                {
                  id: "second",
                  kind: "insert",
                  oldLine: null,
                  newLine: 4,
                  text: "rd",
                },
              ],
      };
    throw Error("Unmocked command " + cmd);
  },
  { shouldMockEvents: true },
);
const source =
  (await readFile("frontend/main.ts", "utf8")).replace(
    'import "./style.css";',
    "",
  ) +
  "\nexport {active,foreground,resolve,closeWindow,editor,past,activate,openFolder,action,flush,buffers,save,selectedChanges,restoreChanges,mappedSelection,renderStage,commit,stage,busy,decorations,filterQuick,quickMatches,menuAvailability};";
await mkdir("node_modules/.cache", { recursive: true });
const built = await build({
  stdin: {
    contents: source,
    resolveDir: process.cwd() + "/frontend",
    loader: "ts",
  },
  bundle: true,
  packages: "external",
  platform: "node",
  format: "esm",
  write: false,
});
await writeFile(
  "node_modules/.cache/editor-smoke.mjs",
  built.outputFiles[0].text,
);
const app = await import("../node_modules/.cache/editor-smoke.mjs");
try {
  assert.equal(document.querySelector(".editor-stack").hidden, true);
  assert.equal(document.querySelector("#edit-mode").disabled, true);
  assert.equal(document.querySelector("header"), null);
  assert.equal(app.menuAvailability().find, false);
  assert.equal(app.menuAvailability().save, false);
  assert.equal(app.menuAvailability().quick, false);
  assert.equal(app.menuAvailability().open, true);
  // The preloaded editor can initialize while the picker has no selection.
  window.history.replaceState(null, "", "/?warm=1");
  const opening = app.startWindow();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(startupReads, 1);
  assert.equal(app.menuAvailability().quick, false);
  startupFolder = "/fixture";
  await emit("startup-folder");
  await opening;
  assert.equal(startupReads, 2);
  assert.ok(
    document.querySelector(".tree").textContent.includes("fixture.tex"),
  );
  window.history.replaceState(null, "", "/");
  assert.equal(document.querySelector("#welcome-open"), null);
  assert.equal(document.querySelector("#edit-mode").disabled, false);
  assert.equal(app.menuAvailability().quick, true);
  assert.equal(app.menuAvailability().find, false);
  assert.ok(
    [...document.querySelectorAll(".tree button")].every((row) =>
      row.firstElementChild.classList.contains("tree-leading"),
    ),
  );
  assert.ok(!document.querySelector(".tree").textContent.includes("📁"));
  await app.activate("fixture.tex");
  assert.equal(app.editor.state.doc.toString(), base);
  assert.equal(app.past.state.doc.toString(), base);
  assert.equal(app.menuAvailability().find, true);
  assert.equal(app.menuAvailability().save, false);
  assert.equal(app.menuAvailability().undo, false);
  for (const char of "word") {
    app.editor.dispatch({
      changes: { from: app.editor.state.doc.length, insert: char },
      selection: { anchor: app.editor.state.doc.length + 1 },
      annotations: Transaction.userEvent.of("input.type"),
    });
  }
  const immediate = [];
  app.editor.state
    .field(app.decorations)
    .between(0, app.editor.state.doc.length, (from, to) =>
      immediate.push([from, to]),
    );
  assert.deepEqual(immediate, [[base.length, base.length + 4]]);
  assert.equal(app.menuAvailability().save, true);
  assert.equal(app.menuAvailability().undo, true);
  await app.flush(app.buffers.get("fixture.tex"));
  assert.equal(text, base + "word");
  await app.action("undo");
  await app.flush(app.buffers.get("fixture.tex"));
  assert.equal(app.editor.state.doc.toString(), base);
  await app.action("redo");
  await app.flush(app.buffers.get("fixture.tex"));
  assert.equal(app.editor.state.doc.toString(), base + "word");
  await app.save();
  assert.equal(disk, text);
  app.editor.dispatch({ selection: { anchor: 0 } });
  document.dispatchEvent(
    new KeyboardEvent("keydown", {
      key: "]",
      code: "BracketRight",
      metaKey: true,
      bubbles: true,
      cancelable: true,
    }),
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(app.editor.state.selection.main.head, base.length);
  const buffer = app.buffers.get("fixture.tex");
  const originalChanges = buffer.changes;
  buffer.changes = [
    { a: 1, aEnd: 2, b: 1, bEnd: 2 },
    { a: 3, aEnd: 4, b: 3, bEnd: 3 },
    { a: 5, aEnd: 6, b: 5, bEnd: 6 },
    { a: 22, aEnd: 23, b: 22, bEnd: 23 },
  ];
  async function bracket(code, altKey = false) {
    document.dispatchEvent(
      new KeyboardEvent("keydown", {
        code,
        metaKey: true,
        altKey,
        bubbles: true,
        cancelable: true,
      }),
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  app.editor.dispatch({ selection: { anchor: 1 } });
  await bracket("BracketRight");
  assert.equal(app.editor.state.selection.main.head, 22);
  await bracket("BracketLeft");
  assert.equal(app.editor.state.selection.main.head, 1);
  app.editor.dispatch({ selection: { anchor: 0 } });
  await bracket("BracketRight", true);
  assert.equal(app.editor.state.selection.main.head, 1);
  await bracket("BracketRight", true);
  assert.equal(app.editor.state.selection.main.head, 5);
  await bracket("BracketLeft", true);
  assert.equal(app.editor.state.selection.main.head, 1);
  buffer.changes = originalChanges;
  document.querySelector("#commit-mode").click();
  assert.equal(
    document.querySelector("#commit-mode").getAttribute("aria-pressed"),
    "true",
  );
  await app.renderStage();
  assert.equal(document.querySelector("#branch").hidden, false);
  const rows = document.querySelectorAll(".stage-row input");
  assert.equal(rows.length, 2);
  assert.equal(document.querySelectorAll(".tree [data-path]").length, 1);
  rows[0].checked = false;
  rows[0].onchange();
  assert.equal(
    document.querySelector(".tree [data-path] input").indeterminate,
    true,
  );
  assert.equal(document.querySelector(".stage-tools"), null);
  document.querySelector("#edit-mode").click();
  assert.equal(document.querySelector("#branch").hidden, true);
  app.editor.dispatch({
    selection: { anchor: base.length, head: app.editor.state.doc.length },
  });
  app.buffers.get("fixture.tex").changes = [
    {
      a: base.length,
      aEnd: base.length,
      b: base.length,
      bEnd: base.length + 2,
    },
    {
      a: base.length,
      aEnd: base.length,
      b: base.length + 2,
      bEnd: base.length + 4,
    },
  ];
  assert.deepEqual(app.mappedSelection(), [
    [base.length, base.length],
    [base.length, base.length],
  ]);
  app.past.dispatch({ selection: { anchor: 0, head: 8 } });
  assert.deepEqual(app.mappedSelection(true), [[0, 8]]);
  const selected = app.selectedChanges();
  assert.equal(selected.length, 2);
  app.restoreChanges(selected);
  assert.equal(app.editor.state.doc.toString(), base);
  await app.flush(app.buffers.get("fixture.tex"));
  await app.action("undo");
  assert.equal(app.editor.state.doc.toString(), base + "word");
  await app.flush(app.buffers.get("fixture.tex"));
  document.dispatchEvent(
    new KeyboardEvent("keydown", {
      key: "f",
      metaKey: true,
      bubbles: true,
      cancelable: true,
    }),
  );
  assert.equal(document.querySelector(".search").hidden, false);
  await app.action("replace");
  assert.equal(document.querySelector("#replace-row").hidden, false);
  await app.flush(app.buffers.get("fixture.tex"));
  document.querySelector("#summary").value = "Selected changes";
  const callsBefore = commitCalls;
  await assert.rejects(app.commit(), /buffer changed; review/);
  assert.equal(commitCalls, callsBefore);
  document.querySelector("#commit-mode").click();
  await app.renderStage();
  // Re-review after edits, then explicitly select a single replacement row.
  const reviewChecks = document.querySelectorAll(".stage input:not(:disabled)");
  reviewChecks[0].checked = false;
  reviewChecks[0].dispatchEvent(new Event("change"));
  await app.stage();
  const afterStaging = document.querySelector(".stage input:not(:disabled)");
  assert.ok(afterStaging, "staging keeps the review interactive");
  afterStaging.checked = false;
  afterStaging.dispatchEvent(new Event("change"));
  const committing = app.commit();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(Object.values(app.menuAvailability()).every((v) => !v));
  const before = app.editor.state.doc.toString();
  app.editor.dispatch({ changes: { from: 0, insert: "blocked" } });
  assert.equal(app.editor.state.doc.toString(), before);
  await app.commit();
  assert.equal(commitCalls, 1);
  assert.deepEqual(
    commitSelection.find((s) => s.path === "fixture.tex").selected,
    ["second"],
  );
  holdCommit();
  await committing;
  document.querySelector("#summary").value = "Commit before refresh failure";
  divergedStage = true;
  failNextRefresh = true;
  const committedBeforeRefreshFailure = app.commit();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(
    commitSelection.find((s) => s.path === "fixture.tex").source,
    "index",
  );
  holdCommit();
  await committedBeforeRefreshFailure;
  divergedStage = false;
  assert.equal(document.querySelector("#summary").value, "");
  assert.match(
    document.querySelector(".message").textContent,
    /Committed new-head.*Refresh failed/,
  );
  document.querySelector("#edit-mode").click();
  assert.equal(document.querySelector(".sidebar").inert, false);
  document.querySelector("#query").value = "nonexistent phrase";
  await app.action("find-next");
  assert.equal(document.querySelector("#matches").textContent, "No matches");
  document.querySelector("#query").value = "";
  await app.action("find-next");
  assert.equal(document.activeElement, document.querySelector("#query"));
  let undoTarget = "";
  document.queryCommandEnabled = () => true;
  document.execCommand = (command) => {
    undoTarget = command;
    return true;
  };
  await app.action("undo");
  assert.equal(undoTarget, "undo");
  await app.filterQuick();
  assert.equal(app.quickMatches().length, 300);
  assert.ok(document.querySelectorAll(".quick-list button").length < 60);
  const quickList = document.querySelector(".quick-list");
  quickList.scrollTop = 290 * 28;
  quickList.onscroll();
  assert.ok(quickList.textContent.includes("file-299.tex"));
  app.editor.focus();
  app.editor.dispatch({ selection: { anchor: 0 } });
  await app.action("next-line");
  assert.equal(
    app.editor.state.doc.lineAt(app.editor.state.selection.main.head).number,
    3,
  );
  stageRowCount = 10000;
  document.querySelector("#commit-mode").click();
  await app.renderStage();
  assert.ok(
    document.querySelectorAll(".stage-row").length < 100,
    "large stage view is virtualized",
  );
  const stageView = document.querySelector(".stage");
  stageView.scrollTop = 9000 * 26.15;
  stageView.dispatchEvent(new Event("scroll"));
  assert.ok(
    stageView.textContent.includes("9001"),
    "scrolling renders distant rows",
  );
  const firstCheck = stageView.querySelector("input:not(:disabled)");
  firstCheck.focus();
  stageView.scrollTop += 1000;
  stageView.dispatchEvent(new Event("scroll"));
  assert.equal(
    document.activeElement,
    firstCheck,
    "scroll preserves the focused input",
  );
  firstCheck.dispatchEvent(
    new KeyboardEvent("keydown", {
      key: "End",
      bubbles: true,
      cancelable: true,
    }),
  );
  assert.equal(
    document.activeElement.closest("[data-virtual-index]").dataset.virtualIndex,
    "9999",
  );
  document.activeElement.dispatchEvent(
    new KeyboardEvent("keydown", {
      key: "Home",
      bubbles: true,
      cancelable: true,
    }),
  );
  assert.equal(
    document.activeElement.closest("[data-virtual-index]").dataset.virtualIndex,
    "0",
  );
  stageRowCount = 2;
  document.querySelector("#edit-mode").click();
  // Inspecting external state must not discard typing or install stale ranges.
  await app.save();
  let releaseInspection;
  inspectionGate = new Promise((resolve) => (releaseInspection = resolve));
  const inspecting = app.foreground();
  await new Promise((resolve) => setTimeout(resolve, 0));
  app.editor.dispatch({
    changes: { from: app.editor.state.doc.length, insert: "!" },
  });
  await app.flush(app.active);
  releaseInspection();
  await inspecting;
  assert.ok(app.editor.state.doc.toString().endsWith("!"));
  await app.save();
  disk = "External replacement.\n";
  await app.foreground();
  assert.equal(app.editor.state.doc.toString(), disk);
  const rangesAfterReload = app.editor.state.field(app.decorations).iter();
  while (rangesAfterReload.value) {
    assert.ok(rangesAfterReload.to <= app.editor.state.doc.length);
    rangesAfterReload.next();
  }
  // Closing establishes a stable snapshot while still allowing modal keyboard input.
  app.editor.dispatch({ changes: { from: 0, insert: "unsaved " } });
  await app.flush(app.active);
  const closingWindow = app.closeWindow();
  await new Promise((resolve) => setTimeout(resolve, 0));
  const stable = app.editor.state.doc.toString();
  app.editor.dispatch({ changes: { from: 0, insert: "blocked" } });
  assert.equal(app.editor.state.doc.toString(), stable);
  const modalKey = new KeyboardEvent("keydown", {
    key: "Tab",
    bubbles: true,
    cancelable: true,
  });
  document.querySelector(".modal").dispatchEvent(modalKey);
  assert.equal(modalKey.defaultPrevented, false);
  [...document.querySelectorAll(".modal-actions button")]
    .find((b) => b.textContent === "Cancel")
    .click();
  await closingWindow;
  assert.equal(document.querySelector(".sidebar").inert, false);
  // Repeated sidebar clicks must not reinstall the current editor state.
  const originalSetState = app.editor.setState;
  let stateResets = 0;
  app.editor.setState = function (state) {
    stateResets++;
    return originalSetState.call(this, state);
  };
  const selectionBefore = app.editor.state.selection.toJSON();
  const scrollBefore = app.editor.scrollDOM.scrollTop;
  const pastScrollBefore = app.past.scrollDOM.scrollTop;
  for (let i = 0; i < 5; i++) await app.activate("fixture.tex");
  assert.equal(stateResets, 0);
  assert.deepEqual(app.editor.state.selection.toJSON(), selectionBefore);
  assert.equal(app.editor.scrollDOM.scrollTop, scrollBefore);
  assert.equal(app.past.scrollDOM.scrollTop, pastScrollBefore);
  app.editor.setState = originalSetState;
  // Switching documents must never carry ranges from a longer file into a shorter one.
  for (const path of [
    "long.tex",
    "short.tex",
    "long.tex",
    "short.tex",
    "fixture.tex",
  ]) {
    await app.activate(path);
    const b = app.buffers.get(path);
    assert.equal(app.editor.state.doc.toString(), b.state.doc.toString());
    assert.equal(app.past.state.doc.toString(), b.base);
    for (const view of [app.editor, app.past]) {
      const ranges = view.state.field(app.decorations).iter();
      while (ranges.value) {
        assert.ok(
          ranges.from >= 0 && ranges.to <= view.state.doc.length,
          `${path}: invalid decoration`,
        );
        ranges.next();
      }
    }
    app.editor.dispatch({
      selection: { anchor: app.editor.state.doc.length - 1 },
    });
    // Exercise focus and old selection mapping as well as deep scroll targets.
    app.past.focus();
    app.past.dispatch({ selection: { anchor: app.past.state.doc.length - 1 } });
  }
  app.active.changes = [
    { a: 0, aEnd: 3, b: 0, bEnd: 3 },
    { a: 5, aEnd: 8, b: 5, bEnd: 8 },
  ];
  app.past.focus();
  app.past.dispatch({ selection: { anchor: 0, head: 8 } });
  assert.equal(
    app.selectedChanges().length,
    2,
    "past-pane selection includes both changes",
  );
  assert.equal(app.menuAvailability().restore, true);
  const beforePastRestore = app.editor.state.doc.toString();
  await app.action("restore");
  assert.equal(
    app.editor.state.doc.toString(),
    base.slice(0, 3) +
      beforePastRestore.slice(3, 5) +
      base.slice(5, 8) +
      beforePastRestore.slice(8),
  );
  await app.flush(app.active);
  inspectedPaths.length = 0;
  failInspections = true;
  await assert.rejects(app.foreground(), /Cannot inspect/);
  assert.deepEqual(new Set(inspectedPaths), new Set([...app.buffers.keys()]));
  failInspections = false;
  localStorage.setItem(
    "preferences",
    JSON.stringify({
      font: 20,
      wrap: false,
      whitespace: true,
      pastHeight: 999,
    }),
  );
  // A local change must preserve another window's newer unrelated fields.
  await app.action("whitespace");
  assert.equal(JSON.parse(localStorage.getItem("preferences")).font, 20);
  window.dispatchEvent(
    new window.StorageEvent("storage", { key: "preferences" }),
  );
  assert.equal(
    document.documentElement.style.getPropertyValue("--font"),
    "20px",
  );
  assert.equal(
    document.documentElement.style.getPropertyValue("--past"),
    "45px",
  );
  // The clean cache is bounded without dropping an edited document's history.
  for (let i = 0; i < 40; i++) {
    const path = `cache-${i}.txt`;
    switchDocuments[path] = {
      path,
      base: "cache\n",
      text: "cache\n",
      disk: "cache\n",
      version: 0,
      head: "h",
      baseExists: true,
    };
    await app.activate(path);
  }
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(app.buffers.size <= 32);
  assert.ok(releasedPaths.length >= 8);
  assert.ok(app.buffers.has("fixture.tex"), "edited history remains available");
  await app.activate("cache-0.txt");
  assert.equal(app.active.state.doc.toString(), "cache\n");
  console.log(
    "Editor parity: immediate paint, undo, search, navigation, staging, commit lock/selection, Quick Open virtualization: passed",
  );
} finally {
  app.editor.destroy();
  app.past.destroy();
  await dom.happyDOM.close();
}
