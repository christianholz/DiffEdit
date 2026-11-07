export function bounded(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(min, Math.min(max, value))
    : fallback;
}
export function readPreferences(storage: Pick<Storage, "getItem">) {
  let value: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(storage.getItem("preferences") || "{}");
    if (parsed && typeof parsed === "object") value = parsed;
  } catch {
    /* Ignore invalid persisted preferences. */
  }
  const font = bounded(value.font, 13, 9, 32);
  return {
    wrap: typeof value.wrap === "boolean" ? value.wrap : true,
    whitespace:
      typeof value.whitespace === "boolean" ? value.whitespace : false,
    font,
    pastHeight: bounded(value.pastHeight, 5 * font * 1.55 + 16, 45, 1000),
    sidebarWidth: bounded(
      storage.getItem("sidebarWidth") === null
        ? undefined
        : Number(storage.getItem("sidebarWidth")),
      240,
      150,
      550,
    ),
  };
}
