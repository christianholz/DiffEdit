import { EditorSelection, StateField } from "@codemirror/state";
import {
  DecorationSet,
  EditorView,
  layer,
  RectangleMarker,
  WidgetType,
} from "@codemirror/view";

// Keep the anchors in the same mapped range sets as the text highlights.
// An inline widget (even at zero width) introduces a word break in WebKit.
export class Marker extends WidgetType {
  constructor(
    readonly green = false,
    readonly horizontal = false,
  ) {
    super();
  }
  eq(other: WidgetType) {
    return (
      other instanceof Marker &&
      other.green === this.green &&
      other.horizontal === this.horizontal
    );
  }
  toDOM(): never {
    throw new Error("Diff markers are drawn in an editor layer");
  }
}

export function diffMarkers(...fields: StateField<DecorationSet>[]) {
  return layer({
    above: false,
    class: "diff-markers",
    update: (update) =>
      update.viewportChanged ||
      update.selectionSet ||
      fields.some(
        (field) => update.startState.field(field) !== update.state.field(field),
      ),
    markers(view) {
      const result: RectangleMarker[] = [];
      const row =
        parseFloat(getComputedStyle(view.contentDOM).lineHeight) * view.scaleY;
      const bounds = view.scrollDOM.getBoundingClientRect();
      const left =
        (getComputedStyle(view.contentDOM).direction === "rtl"
          ? bounds.right - view.scrollDOM.clientWidth * view.scaleX
          : bounds.left) -
        view.scrollDOM.scrollLeft * view.scaleX;
      const top = bounds.top - view.scrollDOM.scrollTop * view.scaleY;
      const range = view.dom.ownerDocument.createRange();
      for (const field of fields) {
        view.state
          .field(field)
          .between(view.viewport.from, view.viewport.to, (pos, to, value) => {
            const marker = value.spec.widget;
            const active =
              view.state.doc.lineAt(pos).number ===
              view.state.doc.lineAt(view.state.selection.main.head).number;
            if (!(marker instanceof Marker)) {
              const name =
                "diff-fill " + value.spec.class + (active ? " active" : "");
              // Selection rectangles fill to the viewport edge at line
              // breaks. Measure the rendered text instead, one line at a time.
              for (const visible of view.visibleRanges) {
                const end = Math.min(to, visible.to);
                for (let from = Math.max(pos, visible.from); from < end;) {
                  const line = view.state.doc.lineAt(from);
                  const stop = Math.min(line.to, end);
                  if (stop > from) {
                    const a = view.domAtPos(from, 1);
                    const b = view.domAtPos(stop, -1);
                    range.setStart(a.node, a.offset);
                    range.setEnd(b.node, b.offset);
                    const rects = [...range.getClientRects()];
                    for (const [i, rect] of rects.entries()) {
                      if (
                        !rect.width ||
                        rects.some(
                          (other, j) =>
                            j !== i &&
                            other.top <= rect.top &&
                            other.bottom >= rect.bottom &&
                            other.left <= rect.left &&
                            other.right >= rect.right &&
                            (j < i ||
                              other.width > rect.width ||
                              other.height > rect.height),
                        )
                      )
                        continue;
                      const height = Math.max(rect.height, row || 0);
                      result.push(
                        new RectangleMarker(
                          name,
                          rect.left - left,
                          rect.top - top - (height - rect.height) / 2,
                          rect.width,
                          height,
                        ),
                      );
                    }
                  }
                  from = stop + 1;
                }
              }
              return;
            }
            const name =
              "diff-marker" +
              (marker.green ? " insert" : active ? " active" : "") +
              (marker.horizontal ? " line" : "");
            const [anchor] = RectangleMarker.forRange(
              view,
              name,
              EditorSelection.cursor(pos, value.spec.side),
            );
            if (!anchor) return;
            if (marker.horizontal) {
              const content = view.contentDOM.getBoundingClientRect();
              const row = view.scrollDOM.getBoundingClientRect();
              const line = view.contentDOM.querySelector(".cm-line");
              const padding = line
                ? parseFloat(getComputedStyle(line).paddingLeft)
                : 0;
              result.push(
                new RectangleMarker(
                  name,
                  content.left - row.left + view.scrollDOM.scrollLeft + padding,
                  anchor.top,
                  Math.max(0, content.width - padding * 2),
                  2,
                ),
              );
            } else {
              result.push(
                new RectangleMarker(
                  name,
                  anchor.left - 2,
                  anchor.top + 1,
                  4,
                  Math.max(1, anchor.height - 2),
                ),
              );
            }
          });
      }
      return result;
    },
  });
}
