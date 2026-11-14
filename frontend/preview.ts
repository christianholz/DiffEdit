import { Transaction } from "@codemirror/state";
import { Change } from "./model";
// Update only the ranges touched by this transaction. The worker subsequently
// refines correspondence; immediate painting never waits for that round trip.
export function previewChanges(
  previous: Change[],
  base: string,
  tr: Transaction,
): Change[] {
  const map = (pos: number, end = false) => {
    let delta = 0;
    for (const c of previous) {
      if (pos < c.b) break;
      if (pos < c.bEnd || (pos === c.b && c.b === c.bEnd))
        return end ? c.aEnd : c.a;
      delta = c.aEnd - c.bEnd;
    }
    return pos + delta;
  };
  const covered = new Set<Change>();
  const result: Change[] = [];
  const edited: Array<[number, number]> = [];
  tr.changes.iterChanges((from, to, newFrom, newTo) => {
    edited.push([newFrom, newTo]);
    let a = map(from),
      aEnd = map(to, true),
      b = newFrom,
      bEnd = newTo;
    for (const c of previous) {
      if (c.b > to) break;
      if (c.bEnd < from) continue;
      covered.add(c);
      a = Math.min(a, c.a);
      aEnd = Math.max(aEnd, c.aEnd);
      b = Math.min(b, tr.changes.mapPos(c.b, -1));
      bEnd = Math.max(bEnd, tr.changes.mapPos(c.bEnd, 1));
    }
    result.push({ a, aEnd, b, bEnd });
  });
  for (const c of previous)
    if (!covered.has(c))
      result.push({
        ...c,
        b: tr.changes.mapPos(c.b, -1),
        bEnd: tr.changes.mapPos(c.bEnd, 1),
      });
  result.sort((a, b) => a.b - b.b || a.a - b.a);
  const merged: Change[] = [];
  for (const c of result) {
    const last = merged.at(-1);
    if (last && c.a <= last.aEnd && c.b < last.bEnd) {
      last.aEnd = Math.max(last.aEnd, c.aEnd);
      last.bEnd = Math.max(last.bEnd, c.bEnd);
    } else merged.push({ ...c });
  }
  return merged
    .map((c) => {
      if (!edited.some(([from, to]) => c.b <= to && c.bEnd >= from)) return c;
      // Bound synchronous work for large paste/replacement operations.
      if (c.aEnd - c.a + c.bEnd - c.b > 8192) return c;
      const old = base.slice(c.a, c.aEnd),
        now = tr.newDoc.sliceString(c.b, c.bEnd);
      let left = 0,
        right = 0;
      while (left < old.length && left < now.length && old[left] === now[left])
        left++;
      if (left && /[\uD800-\uDBFF]/.test(old[left - 1])) left--;
      while (
        right < old.length - left &&
        right < now.length - left &&
        old[old.length - 1 - right] === now[now.length - 1 - right]
      )
        right++;
      if (right && /[\uDC00-\uDFFF]/.test(old[old.length - right])) right--;
      // Trim whole words freely, but retain weak fragments as changed text.
      const word = /[\p{L}\p{N}\p{M}_]/u;
      const boundary = (before: string, after: string) =>
        !word.test(before) || !word.test(after);
      const keep = (fragment: string, atEdge: boolean) =>
        (fragment.match(/\p{L}\p{M}*/gu)?.length ?? 0) >= (atEdge ? 3 : 4);
      if (left < old.length || left < now.length) {
        const tail =
          old.slice(0, left).match(/[\p{L}\p{N}\p{M}_]+$/u)?.[0] ?? "";
        if (
          tail &&
          (word.test(old[left] ?? "") || word.test(now[left] ?? ""))
        ) {
          const start = left - tail.length;
          const atEdge =
            boundary((start ? old[start - 1] : base[c.a - 1]) ?? "", tail) &&
            boundary(
              start
                ? now[start - 1]
                : tr.newDoc.sliceString(Math.max(0, c.b - 1), c.b),
              tail,
            );
          if (!keep(tail, atEdge)) left = start;
        }
        const tailStart = old.length - right;
        const head =
          old.slice(tailStart).match(/^[\p{L}\p{N}\p{M}_]+/u)?.[0] ?? "";
        if (
          head &&
          (word.test(old[tailStart - 1] ?? "") ||
            word.test(now[now.length - right - 1] ?? ""))
        ) {
          const atEdge =
            !word.test(old[tailStart + head.length] ?? base[c.aEnd] ?? "") &&
            !word.test(
              now[now.length - right + head.length] ??
                tr.newDoc.sliceString(c.bEnd, c.bEnd + 1),
            );
          if (!keep(head, atEdge)) right -= head.length;
        }
      }
      return {
        a: c.a + left,
        aEnd: c.aEnd - right,
        b: c.b + left,
        bEnd: c.bEnd - right,
      };
    })
    .filter((c) => c.a !== c.aEnd || c.b !== c.bEnd);
}
