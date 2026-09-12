import { test } from "node:test";
import assert from "node:assert/strict";
import { basePosition, changeAt, wordRange, visible } from "./model";
test("one alignment drives equal text, replacement edges and pure insertions", () => {
  const changes = [
    { a: 3, aEnd: 7, b: 3, bEnd: 9 },
    { a: 12, aEnd: 12, b: 14, bEnd: 18 },
  ];
  const boundary = [
    { a: 0, aEnd: 30, b: 0, bEnd: 0 },
    { a: 30, aEnd: 40, b: 0, bEnd: 15 },
  ];
  assert.equal(changeAt(boundary, 0), boundary[1]);
  assert.equal(basePosition(changes, 11), 9);
  assert.equal(basePosition(changes, 20), 14);
  assert.equal(changeAt(changes, 9), changes[0]);
  assert.equal(changeAt(changes, 16), changes[1]);
  assert.deepEqual(wordRange("factual knowledge", 7), [0, 7]);
  assert.equal(
    visible({ a: 0, aEnd: 1, b: 0, bEnd: 4 }, "\t", "    ", false),
    false,
  );
});

import { EditorState } from "@codemirror/state";
import { previewChanges } from "./preview";
test("immediate ranges survive typing, reverting, whitespace edges and multiple cursors", () => {
  const cases = [
    {
      base: " a ",
      now: " a ",
      prior: [],
      edits: { from: 1, to: 2, insert: "the" },
      expected: [{ a: 1, aEnd: 2, b: 1, bEnd: 4 }],
    },
    {
      base: "abc",
      now: "axbc",
      prior: [{ a: 1, aEnd: 1, b: 1, bEnd: 2 }],
      edits: { from: 1, to: 2, insert: "" },
      expected: [],
    },
    {
      base: "",
      now: "abcd",
      prior: [{ a: 0, aEnd: 0, b: 0, bEnd: 4 }],
      edits: [
        { from: 1, insert: "x" },
        { from: 3, insert: "y" },
      ],
      expected: [{ a: 0, aEnd: 0, b: 0, bEnd: 6 }],
    },
    {
      base: "a 🦀 b",
      now: "a 🦀 b",
      prior: [],
      edits: { from: 2, to: 4, insert: "🐝" },
      expected: [{ a: 2, aEnd: 4, b: 2, bEnd: 4 }],
    },
  ];
  for (const c of cases) {
    const tr = EditorState.create({ doc: c.now }).update({ changes: c.edits });
    assert.deepEqual(previewChanges(c.prior, c.base, tr), c.expected);
  }
});
