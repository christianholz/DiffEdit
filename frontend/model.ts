import type { Text } from "@codemirror/state";
export interface Change {
  a: number;
  aEnd: number;
  b: number;
  bEnd: number;
}
export function positionAfterReload(changes: Change[], pos: number) {
  let delta = 0;
  for (const change of changes) {
    if (pos < change.a) break;
    if (pos < change.aEnd)
      return change.b + Math.min(pos - change.a, change.bEnd - change.b);
    delta = change.bEnd - change.aEnd;
  }
  return pos + delta;
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
  partialStaged?: string[];
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
/** Display replacements in pairs without changing Git's patch order. */
export function pairedStageRows(rows: readonly StageRow[]): StageRow[] {
  const paired: StageRow[] = [];
  let i = 0;
  while (i < rows.length) {
    if (rows[i].kind !== "delete") {
      paired.push(rows[i++]);
      continue;
    }
    const start = i;
    while (i < rows.length && rows[i].kind === "delete") i++;
    const inserted = i;
    while (i < rows.length && rows[i].kind === "insert") i++;
    for (
      let offset = 0;
      offset < Math.max(inserted - start, i - inserted);
      offset++
    ) {
      if (start + offset < inserted) paired.push(rows[start + offset]);
      if (inserted + offset < i) paired.push(rows[inserted + offset]);
    }
  }
  return paired;
}
export interface DiffUpdate {
  version: number;
  head: string | null;
  diff: Diff;
}
export interface StageSnapshot {
  source: "buffer" | "index";
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
/** Keep separators in the actual edit, but paint only the inserted content. */
export function insertionHighlight(
  doc: Text,
  from: number,
  to: number,
): [number, number] {
  for (const chunk of doc.iterRange(from, to)) {
    const first = chunk.search(/\S/u);
    if (first >= 0) {
      from += first;
      break;
    }
    from += chunk.length;
  }
  if (from === to) return [from, to];
  for (const chunk of doc.iterRange(to, from)) {
    const trailing = chunk.match(/\s*$/u)![0].length;
    to -= trailing;
    if (trailing < chunk.length) break;
  }
  return [from, to];
}
// A deletion marker has no changed text to land on in the current editor.
export function visibleInNow(
  c: Change,
  base: string,
  current: Text,
  whitespace: boolean,
) {
  return c.bEnd > c.b && visible(c, base, current, whitespace);
}

export function changedLineTargets(
  changes: Change[],
  base: string,
  doc: Text,
  whitespace: boolean,
  byLine: boolean,
) {
  const targets: { line: number; pos: number }[] = [];
  let last = 0;
  for (const c of changes) {
    if (!visibleInNow(c, base, doc, whitespace)) continue;
    const start = doc.lineAt(c.b).number;
    const end = doc.lineAt(c.bEnd - 1).number;
    for (let line = Math.max(last + 1, start); line <= end; line++) {
      if (byLine || line > last + 1 || last === 0) {
        targets.push({ line, pos: line === start ? c.b : doc.line(line).from });
      }
      last = line;
    }
  }
  return targets;
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
