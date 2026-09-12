import { EditorView, ViewPlugin } from "@codemirror/view";

function capacity(view: EditorView) {
  const parent = view.dom.parentElement!;
  const style = getComputedStyle(parent);
  const available =
    (parseFloat(style.getPropertyValue("--past")) || parent.clientHeight) -
    parseFloat(style.paddingTop) -
    parseFloat(style.paddingBottom);
  return Math.max(1, Math.floor(available / view.defaultLineHeight));
}

function snap(view: EditorView, top: number) {
  const line = view.defaultLineHeight;
  const max = Math.max(
    0,
    view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight,
  );
  view.scrollDOM.scrollTop = Math.min(
    max,
    Math.max(0, Math.round(top / line) * line),
  );
}

// Size and scroll in visual rows, including wrapped rows rather than source lines.
export const pastViewport = [
  ViewPlugin.fromClass(
    class {
      observer: ResizeObserver;
      constructor(readonly view: EditorView) {
        this.observer = new ResizeObserver(() => this.measure());
        this.observer.observe(view.dom.parentElement!);
        this.observer.observe(view.contentDOM);
        view.scrollDOM.addEventListener("scroll", this.onScroll);
        this.measure();
      }
      onScroll = () => snap(this.view, this.view.scrollDOM.scrollTop);
      update() {
        this.measure();
      }
      measure() {
        this.view.requestMeasure({
          key: this,
          read: (view) => {
            const style = getComputedStyle(view.dom.parentElement!);
            const height = capacity(view) * view.defaultLineHeight;
            return {
              height,
              outer:
                height +
                parseFloat(style.paddingTop) +
                parseFloat(style.paddingBottom),
            };
          },
          write: ({ height, outer }, view) => {
            // Shrink the container too: otherwise its unused remainder becomes
            // a blank strip between the last complete row and the divider.
            const parent = view.dom.parentElement!;
            if (parent.style.height !== `${outer}px`)
              parent.style.height = `${outer}px`;
            if (view.dom.style.height !== `${height}px`)
              view.dom.style.height = `${height}px`;
            snap(view, view.scrollDOM.scrollTop);
          },
        });
      }
      destroy() {
        this.observer.disconnect();
        this.view.scrollDOM.removeEventListener("scroll", this.onScroll);
      }
    },
  ),
  EditorView.scrollHandler.of((view, range) => {
    const line = view.defaultLineHeight;
    const contentTop = view.contentDOM.getBoundingClientRect().top;
    const row = (pos: number) => {
      // scrollHandler runs during CodeMirror's write phase: coordsAtPos would
      // initiate a forbidden editor measurement here. Use the rendered DOM.
      const at = view.domAtPos(pos);
      const rect = document.createRange();
      rect.setStart(at.node, at.offset);
      rect.setEnd(
        at.node,
        at.node.nodeType === Node.TEXT_NODE
          ? Math.min(at.offset + 1, at.node.textContent!.length)
          : at.offset,
      );
      const coords = rect.getClientRects()[0];
      const top = coords ? coords.top - contentTop : view.lineBlockAt(pos).top;
      return Math.floor((top + 0.5) / line);
    };
    const first = row(range.from);
    const last = row(
      range.empty ? range.to : Math.max(range.from, range.to - 1),
    );
    const visible = capacity(view);
    // Large selections end one row before the viewport's bottom. Short ranges
    // retain centered context. The entire viewport always starts on a row edge.
    const top =
      last - first + 1 > visible - 2 && !range.empty
        ? last + 1 + Math.min(1, visible - 1) - visible
        : Math.floor((first + last + 1 - visible) / 2);
    snap(view, top * line);
    // Preserve horizontal following when wrapping is disabled.
    const head = view.domAtPos(range.head);
    const caret = document.createRange();
    caret.setStart(head.node, head.offset);
    caret.collapse(true);
    const rect = caret.getClientRects()[0];
    if (rect) {
      const bounds = view.scrollDOM.getBoundingClientRect();
      if (rect.left < bounds.left + 20)
        view.scrollDOM.scrollLeft += rect.left - bounds.left - 20;
      else if (rect.right > bounds.right - 20)
        view.scrollDOM.scrollLeft += rect.right - bounds.right + 20;
    }
    return true;
  }),
];

// Main-pane scrolling can originate in navigation, restored file positions, or
// wheel input. Align all of those paths at the same visual-row boundary.
export const wholeRowScroll = ViewPlugin.fromClass(
  class {
    constructor(readonly view: EditorView) {
      view.scrollDOM.addEventListener("scroll", this.onScroll);
    }
    onScroll = () => snap(this.view, this.view.scrollDOM.scrollTop);
    update() {
      this.view.requestMeasure({
        key: this,
        read: (view) => view.scrollDOM.clientHeight % view.defaultLineHeight,
        write: (remainder, view) => {
          // Make the maximum scroll offset a row boundary too, so reaching the
          // document end does not reintroduce a clipped first row.
          const padding = `${remainder}px`;
          if (view.contentDOM.style.paddingBottom !== padding)
            view.contentDOM.style.setProperty(
              "padding-bottom",
              padding,
              "important",
            );
          snap(view, view.scrollDOM.scrollTop);
        },
      });
    }
    destroy() {
      this.view.scrollDOM.removeEventListener("scroll", this.onScroll);
    }
  },
);
