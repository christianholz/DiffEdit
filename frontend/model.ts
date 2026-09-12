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
  branch: string;
  files: string[];
  changed: string[];
  staged: string[];
}
export interface Document {
  path: string;
  text: string;
  base: string;
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
export function visible(
  c: Change,
  base: string,
  current: string,
  whitespace: boolean,
) {
  return (
    whitespace ||
    /\S/u.test(base.slice(c.a, c.aEnd) + current.slice(c.b, c.bEnd))
  );
}
export function changeAt(changes: Change[], pos: number): Change | undefined {
  return (
    changes.find((c) => c.b === pos && c.bEnd > pos) ||
    changes.find((c) => c.b === c.bEnd && c.b === pos) ||
    changes.find((c) => c.b < pos && pos <= c.bEnd) ||
    changes.find((c) => c.b === pos && c.bEnd > pos)
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
  let p = Math.max(0, Math.min(pos, text.length));
  const word = (c: string) => /[\p{L}\p{N}_\\]/u.test(c);
  if (p > 0 && word(text[p - 1])) p--;
  if (!word(text[p] || "")) return [p, p];
  let a = p,
    b = p + 1;
  while (a > 0 && word(text[a - 1])) a--;
  while (b < text.length && word(text[b])) b++;
  return [a, b];
}
