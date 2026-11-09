import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { BufferStore, DocumentSync } from "./synchronization";
import { DialogQueue } from "./dialogs";
import { readPreferences } from "./preferences";
import { wordRange } from "./model";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const turn = () => new Promise<void>((r) => setImmediate(r));

for (const applied of [false, true])
  test(`edit recovery after ${applied ? "lost acknowledgement" : "rejected edit"} preserves all text`, async () => {
    let state = EditorState.create({ doc: "Original" });
    let native = "Original",
      version = 0,
      nativeVersion = 0;
    let fail = true;
    const sync = new DocumentSync({
      path: "a",
      version: () => version,
      text: () => state.doc.toString(),
      invoke: async <T>(command: string, args: Record<string, unknown>) => {
        if (command === "edit_document") {
          if (!fail || applied) {
            assert.equal(args.version, nativeVersion + 1);
            for (const edit of (
              args.edits as { from: number; to: number; insert: string }[]
            )
              .slice()
              .reverse())
              native =
                native.slice(0, edit.from) +
                edit.insert +
                native.slice(edit.to);
            nativeVersion++;
          }
          if (fail) {
            fail = false;
            throw Error("transport failed");
          }
        } else {
          native = args.text as string;
          nativeVersion++;
        }
        return {
          version: nativeVersion,
          head: "h",
          diff: { changes: [], micros: 0 },
        } as T;
      },
      receive: (update) => {
        version = update.version;
      },
      fail: (error) => assert.fail(String(error)),
    });
    const edit = (from: number, insert: string) => {
      const tr = state.update({ changes: { from, to: from + 1, insert } });
      state = tr.state;
      sync.enqueue(tr.changes);
    };
    edit(0, "X");
    await sync.flush();
    edit(1, "Y");
    await sync.flush();
    assert.equal(native, "XYiginal");
    assert.equal(native, state.doc.toString());
  });

test("edits arriving during a request drain without another keystroke or save", async () => {
  let state = EditorState.create({ doc: "a" }),
    version = 0;
  const gate = deferred<void>();
  const calls: string[] = [];
  const sync = new DocumentSync({
    path: "a",
    version: () => version,
    text: () => state.doc.toString(),
    invoke: async <T>(_command: string, args: Record<string, unknown>) => {
      calls.push(JSON.stringify(args.edits));
      if (calls.length === 1) await gate.promise;
      return {
        version: ++version,
        head: null,
        diff: { changes: [], micros: 0 },
      } as T;
    },
    receive: () => {},
    fail: (error) => assert.fail(String(error)),
  });
  for (const insert of ["b", "c"]) {
    const tr = state.update({ changes: { from: state.doc.length, insert } });
    state = tr.state;
    sync.enqueue(tr.changes);
    await turn();
  }
  gate.resolve();
  await turn();
  await turn();
  assert.equal(calls.length, 2);
  await sync.flush();
});

test("failed recovery remains retryable with no new edit", async () => {
  let state = EditorState.create({ doc: "a" }),
    version = 0,
    available = false,
    native = "a";
  const sync = new DocumentSync({
    path: "a",
    version: () => version,
    text: () => state.doc.toString(),
    invoke: async <T>(_command: string, args: Record<string, unknown>) => {
      if (!available) throw Error("offline");
      native = args.text as string;
      return { version: 1, head: null, diff: { changes: [], micros: 0 } } as T;
    },
    receive: (u) => {
      version = u.version;
    },
    fail: () => {},
  });
  const tr = state.update({ changes: { from: 1, insert: "b" } });
  state = tr.state;
  sync.enqueue(tr.changes);
  await assert.rejects(sync.flush(), /offline/);
  available = true;
  await sync.flush();
  assert.equal(native, "ab");
});

test("pending opens share an identity and cannot repopulate a cleared workspace", async () => {
  const store = new BufferStore<object>(),
    gate = deferred<object>();
  let calls = 0;
  const first = store.load("a", () => {
    calls++;
    return gate.promise;
  });
  const second = store.load("a", async () => {
    calls++;
    return {};
  });
  assert.equal(first, second);
  const buffer = {};
  gate.resolve(buffer);
  assert.equal(await first, buffer);
  assert.equal(store.get("a"), buffer);
  assert.equal(calls, 1);
  const old = deferred<object>();
  const pending = store.load("b", () => old.promise);
  store.clear();
  old.resolve({});
  await assert.rejects(pending, /Workspace changed/);
  assert.equal(store.size, 0);
});

test("dialogs keep each caller's resolver when requests overlap", async () => {
  const first = deferred<string>();
  const shown: string[] = [];
  const queue = new DialogQueue(async (message) => {
    shown.push(message);
    return message === "first" ? first.promise : "OK";
  });
  const a = queue.choose("first", ["OK"]),
    b = queue.choose("second", ["OK"]);
  await turn();
  assert.deepEqual(shown, ["first"]);
  first.resolve("Cancel");
  assert.equal(await a, "Cancel");
  assert.equal(await b, "OK");
  assert.deepEqual(shown, ["first", "second"]);
});

test("preferences recover from corrupt data and clamp invalid dimensions", () => {
  assert.equal(readPreferences({ getItem: () => "{" }).font, 13);
  const prefs = readPreferences({
    getItem: (key) =>
      key === "preferences"
        ? '{"font":999,"wrap":"false","pastHeight":-10}'
        : "NaN",
  });
  assert.equal(prefs.font, 32);
  assert.equal(prefs.wrap, true);
  assert.equal(prefs.pastHeight, 45);
  assert.equal(prefs.sidebarWidth, 240);
});
test("word correspondence handles astral letters and combining marks", () => {
  assert.deepEqual(wordRange("𐐀bc café", 2), [0, 4]);
  assert.deepEqual(wordRange("𐐀bc café", 9), [5, 10]);
});

test("preferences remain readable when browser storage is unavailable", () => {
  const prefs = readPreferences({
    getItem() {
      throw Error("Storage unavailable");
    },
  });
  assert.equal(prefs.font, 13);
  assert.equal(prefs.sidebarWidth, 240);
  assert.equal(prefs.wrap, true);
});
