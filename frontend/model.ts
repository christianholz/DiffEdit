import type { Text } from "@codemirror/state";
export interface Change {
  a: number;
  aEnd: number;
  b: number;
  bEnd: number;
}
export interface Diff {
  changes: Change[];
  micros: number;
}
export interface Repo {
  root: string;
  gitRoot: string | null;
  prefix: string;
  head: string | null;
  index: string;
  branch: string;
  files: string[];
  changed: string[];
  staged: string[];
}
export interface Document {
  path: string;
  text: string;
  base: string;
  baseExists: boolean;
  head: string | null;
  disk: string | null;
  version: number;
}
export interface StageRow {
  id: string | null;
  kind: string;
  text: string;
  oldLine: number | null;
  newLine: number | null;
}
export interface DiffUpdate {
  version: number;
  head: string | null;
  diff: Diff;
}
export interface StageSnapshot {
  version: number;
  head: string | null;
  index: string;
  rows: StageRow[];
  selected: string[];
}
export function visible(
  c: Change,
  base: string,
  current: string | Text,
  whitespace: boolean,
) {
  if (whitespace || /\S/u.test(base.slice(c.a, c.aEnd))) return true;
  if (typeof current === "string")
    return /\S/u.test(current.slice(c.b, c.bEnd));
  for (const chunk of current.iterRange(c.b, c.bEnd))
    if (/\S/u.test(chunk)) return true;
  return false;
}
export function changeAt(changes: Change[], pos: number): Change | undefined {
  return (
    changes.find((c) => c.b === pos && c.bEnd > pos) ||
    changes.find((c) => c.b === c.bEnd && c.b === pos) ||
    changes.find((c) => c.b < pos && pos <= c.bEnd)
  );
}
export function basePosition(changes: Change[], pos: number): number {
  let delta = 0;
  for (const c of changes) {
    if (pos < c.b) break;
    if (pos <= c.bEnd) return c.a;
    delta = c.aEnd - c.bEnd;
  }
  return pos + delta;
}
export function wordRange(text: string, pos: number): [number, number] {
  const word = (c: string) => /[\p{L}\p{N}\p{M}_\\]/u.test(c);
  let a = Math.max(0, Math.min(pos, text.length));
  if (a > 0 && /[\uDC00-\uDFFF]/.test(text[a])) a--;
  if (a > 0) {
    const previous = a - (/[\uDC00-\uDFFF]/.test(text[a - 1]) ? 2 : 1);
    if (word(String.fromCodePoint(text.codePointAt(previous)!))) a = previous;
  }
  const at = (p: number) => String.fromCodePoint(text.codePointAt(p) ?? 0);
  if (!word(at(a))) return [pos, pos];
  let b = a + at(a).length;
  while (a > 0) {
    const previous = a - (/[\uDC00-\uDFFF]/.test(text[a - 1]) ? 2 : 1);
    if (!word(at(previous))) break;
    a = previous;
  }
  while (b < text.length && word(at(b))) b += at(b).length;
  return [a, b];
}
