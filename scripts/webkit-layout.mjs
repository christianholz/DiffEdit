// macOS rendering regression: reproduce the packaged CSP, not just DOM transactions.
import { build } from "esbuild";
import { readFile, writeFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
const dir = await mkdtemp(join(tmpdir(), "diffedit-layout-"));
const runner = join(dir, "webkit-layout");
execFileSync("clang", [
  "-fobjc-arc",
  "-framework",
  "AppKit",
  "-framework",
  "WebKit",
  "scripts/webkit-layout.m",
  "-o",
  runner,
]);
const css = await readFile("frontend/style.css", "utf8");
for (const withNonce of [false, true]) {
  const result = await build({
    stdin: {
      resolveDir: process.cwd(),
      loader: "ts",
      contents: `
    import {Decoration, EditorView, lineNumbers} from "@codemirror/view";
    import {editorStyleNonce} from "./frontend/editor-style";
    import {pastViewport} from "./frontend/past-viewport";
    import {EditorSelection, StateEffect, StateField} from "@codemirror/state";
    import {diffMarkers, Marker} from "./frontend/diff-markers";
    const view = new EditorView({parent: document.querySelector('.now'), doc: 'Visible paragraph with content.\\n'.repeat(500),
      extensions: [lineNumbers(), EditorView.lineWrapping, ${withNonce ? "editorStyleNonce()," : ""}]});
    const past = ${withNonce} ? new EditorView({parent: document.querySelector('.past'), doc: 'Past row with descenders pg.\\n'.repeat(100), extensions: [lineNumbers(), EditorView.lineWrapping, editorStyleNonce(), pastViewport]}) : null;
    function measureDiffRows() {
      // Sweep widths near wrap boundaries where even 1px can move a word.
      const pane = document.createElement('div');
      pane.className = 'now';
      pane.style.cssText = 'position:absolute;visibility:hidden';
      pane.innerHTML = '<div class="cm-editor"><div class="cm-scroller"><div class="cm-content"><div class="cm-line cm-activeLine"></div></div></div></div>';
      document.body.append(pane);
      const line = pane.querySelector('.cm-line');
      const content = line.parentElement;
      content.style.whiteSpace = 'break-spaces';
      const height = () => line.getBoundingClientRect().height;
      const text = 'one two xyzabcdefghijklmnop three four';
      let wrapShift = 0;
      let verticalDeletionShift = 0;
      for (let width = 200; width <= 320; width++) {
        content.style.width = width + 'px';
        line.textContent = text;
        const plain = height();
        const mark = document.createElement('span');
        mark.className = 'addition';
        mark.textContent = text.slice(8, 11);
        line.replaceChildren(text.slice(0, 8), mark, text.slice(11));
        wrapShift = Math.max(wrapShift, Math.abs(height() - plain));
      }
      pane.replaceChildren();
      const set = StateEffect.define();
      const marks = StateField.define({
        create: () => Decoration.none,
        update: (value, tr) => tr.effects.find(e => e.is(set))?.value ?? value,
      });
      const probe = new EditorView({parent: pane, doc: text, extensions: [
        editorStyleNonce(), EditorView.lineWrapping, marks, diffMarkers(marks),
      ]});
      const rowHeight = () => probe.contentDOM.querySelector('.cm-line').getBoundingClientRect().height;
      let deletionShift = 0;
      for (let width = 200; width <= 320; width++) {
        pane.style.width = width + 'px';
        probe.dispatch({effects: set.of(Decoration.none)});
        const plain = rowHeight();
        for (const horizontal of [false, true]) {
          probe.dispatch({effects: set.of(Decoration.set([
            Decoration.widget({widget: new Marker(false, horizontal), side: -1}).range(11),
          ]))});
          const shift = Math.abs(rowHeight() - plain);
          if (horizontal) deletionShift = Math.max(deletionShift, shift);
          else verticalDeletionShift = Math.max(verticalDeletionShift, shift);
        }
      }
      probe.dispatch({effects: set.of(Decoration.set([
        Decoration.widget({widget: new Marker(), side: -1}).range(11),
      ]))});
      probe.coordsAtPos(11);
      const markerDrawn = !!pane.querySelector('.diff-markers .diff-marker');
      const addition = Decoration.mark({class: 'addition'});
      probe.dispatch({effects: set.of(Decoration.set([addition.range(8, 11)]))});
      probe.coordsAtPos(8);
      const initialFill = pane.querySelector('.diff-fill.addition');
      const initialWidth = parseFloat(initialFill?.style.width);
      probe.dispatch({
        changes: {from: 8, insert: 'x'},
        effects: set.of(Decoration.set([addition.range(8, 12)])),
      });
      probe.coordsAtPos(8);
      const nextFill = pane.querySelector('.diff-fill.addition');
      const fillsStayOutsideText = !!initialFill && nextFill === initialFill &&
        parseFloat(nextFill.style.width) > initialWidth &&
        !probe.contentDOM.querySelector('.addition');
      probe.dispatch({
        changes: {from: 0, to: probe.state.doc.length, insert: 'first row\\nnext row\\n'},
        effects: set.of(Decoration.none),
      });
      const noSeams = ['addition', 'deletion'].every(className => {
        const fill = Decoration.mark({class: className});
        probe.dispatch({effects: set.of(Decoration.set([
          fill.range(0, 5), fill.range(10, 14),
        ]))});
        probe.coordsAtPos(10);
        const rects = [...pane.querySelectorAll('.diff-fill.' + className)]
          .map(node => node.getBoundingClientRect());
        return rects.length === 2 && rects[1].top <= rects[0].bottom &&
          rects[0].bottom - rects[1].top < 0.1;
      });
      const boundedLineEnds = ['addition', 'deletion'].every(className => {
        const fill = Decoration.mark({class: className});
        probe.dispatch({effects: set.of(Decoration.set([fill.range(8, 18)]))});
        const firstEnd = probe.coordsAtPos(9, -1);
        const secondEnd = probe.coordsAtPos(18, -1);
        const rects = [...pane.querySelectorAll('.diff-fill.' + className)]
          .map(node => node.getBoundingClientRect());
        return rects.length === 2 &&
          Math.abs(rects[0].right - firstEnd.right) < 1 &&
          Math.abs(rects[1].right - secondEnd.right) < 1;
      });
      probe.destroy();
      pane.remove();
      return { wrapShift, deletionShift, verticalDeletionShift, markerDrawn, fillsStayOutsideText, noSeams, boundedLineEnds };
    }
    setTimeout(() => {
      // Native WebKit can defer animation-frame measurements in this isolated
      // host. Flush public editor geometry before issuing scroll targets.
      view.coordsAtPos(0);
      if (past) past.coordsAtPos(0);
      if (past) past.dispatch({effects: EditorView.scrollIntoView(EditorSelection.range(past.state.doc.line(30).from, past.state.doc.line(40).to))});
      const scroller = view.scrollDOM;
      const content = view.contentDOM.getBoundingClientRect();
      const gutter = document.querySelector('.cm-gutters').getBoundingClientRect();
      scroller.scrollTop = 607;
      setTimeout(() => {
        view.coordsAtPos(0);
        if (past) past.coordsAtPos(0);
        const result = {
        display: getComputedStyle(scroller).display, contentX: content.x, contentY: content.y,
        gutterRight: gutter.right, scrollTop: scroller.scrollTop, width: scroller.clientWidth, lineHeight: view.defaultLineHeight,
        past: past ? { unused: past.dom.parentElement.clientHeight - 5 - past.dom.getBoundingClientRect().height, height: past.scrollDOM.clientHeight, line: past.defaultLineHeight, top: past.scrollDOM.scrollTop, contentTop: past.contentDOM.getBoundingClientRect().top, row40: past.coordsAtPos(past.state.doc.line(40).from), block40: past.lineBlockAt(past.state.doc.line(40).from).top, cssLine: getComputedStyle(past.contentDOM).lineHeight } : null,
      };
      if (!past) { window.webkit.messageHandlers.result.postMessage(JSON.stringify(result)); return; }
      const wheel = new WheelEvent('wheel', {deltaY: -4, cancelable: true});
      past.scrollDOM.dispatchEvent(wheel);
      result.nativeWheel = !wheel.defaultPrevented;
      const stage = document.createElement('div');
      stage.className = 'stage';
      stage.style.cssText = 'position:absolute;visibility:hidden';
      stage.innerHTML = '<div class="stage-row"><input type="checkbox"><span class="code">sample</span></div>';
      document.getElementById('app').append(stage);
      const editStyle = getComputedStyle(view.contentDOM);
      const commitStyle = getComputedStyle(stage.querySelector('.code'));
      result.sameTypography = ['fontFamily', 'fontSize', 'lineHeight'].every(
        prop => editStyle[prop] === commitStyle[prop],
      );
      result.commitRowHeight = stage.firstElementChild.getBoundingClientRect().height;
      stage.remove();
      const narrow = document.createElement('div');
      narrow.className = 'now';
      narrow.style.cssText = 'position:absolute;visibility:hidden;width:240px;height:180px';
      document.getElementById('app').append(narrow);
      const edge = new EditorView({parent: narrow, doc: 'x'.repeat(150), extensions: [
        lineNumbers(), editorStyleNonce(), EditorView.lineWrapping,
      ]});
      edge.coordsAtPos(0);
      result.wrapsAtEdge =
        edge.scrollDOM.scrollWidth <= edge.scrollDOM.clientWidth + 1 &&
        edge.contentDOM.querySelector('.cm-line').getBoundingClientRect().height >
          edge.defaultLineHeight * 2;
      edge.destroy();
      narrow.remove();
      // Wheel events sent from JS have no default scrolling action. Apply the
      // sub-row offset directly, then wait through the old snap timeout.
      const manualTop = past.scrollDOM.scrollTop - 4;
      past.scrollDOM.scrollTop = manualTop;
      setTimeout(() => {
      past.coordsAtPos(0);
      result.manualScrollTop = past.scrollDOM.scrollTop;
      result.manualScrollTarget = manualTop;
      const wrapped = 'Words with descenders pg and more content. '.repeat(80);
      past.dispatch({changes: {from: 0, to: past.state.doc.length, insert: wrapped}});
      // Use the same selection policy inside one long wrapped source line.
      past.dispatch({effects: EditorView.scrollIntoView(EditorSelection.range(100, 2000))});
      setTimeout(() => {
        const end = past.coordsAtPos(1999);
        const lastRow = Math.floor((end.top - past.contentDOM.getBoundingClientRect().top + .5) / past.defaultLineHeight);
        result.wrapped = {lastRow, top: past.scrollDOM.scrollTop, line: past.defaultLineHeight, height: past.scrollDOM.clientHeight};
        result.diffRows = measureDiffRows();
        window.webkit.messageHandlers.result.postMessage(JSON.stringify(result));
      }, 100);
      }, 150);
      }, 100);
    }, 200);
  `,
    },
    bundle: true,
    write: false,
    format: "iife",
  });
  const html = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-test-script'; style-src 'unsafe-inline' 'nonce-test-style'">
    <style nonce="test-style">${css}</style>
    <div id="app"><div class="workspace"><main class="main"><div class="editor-stack"><div class="past"></div><div class="now-row"><div class="now"></div></div></div></main></div></div>
    <script nonce="test-script">${result.outputFiles[0].text}</script>`;
  const path = join(dir, `${withNonce}.html`);
  await writeFile(path, html);
  const measurements = JSON.parse(
    execFileSync(runner, [path], { encoding: "utf8", timeout: 20000 }).trim(),
  );
  console.log(withNonce ? "Fixed:" : "Original:", measurements);
  assert.equal(measurements.display, withNonce ? "flex" : "block");
  if (withNonce) {
    assert.equal(measurements.nativeWheel, true);
    assert.ok(
      Math.abs(measurements.manualScrollTop - measurements.manualScrollTarget) <
        1,
      "Past keeps a small manual scroll offset without snapping back",
    );
    assert.equal(measurements.wrapsAtEdge, true);
    assert.equal(measurements.sameTypography, true);
    assert.ok(
      Math.abs(measurements.commitRowHeight - measurements.lineHeight) < 0.1,
    );
    assert.deepEqual(measurements.diffRows, {
      wrapShift: 0,
      deletionShift: 0,
      verticalDeletionShift: 0,
      markerDrawn: true,
      fillsStayOutsideText: true,
      noSeams: true,
      boundedLineEnds: true,
    });
    assert.ok(measurements.contentX >= measurements.gutterRight);
    assert.ok(
      measurements.contentY < 150,
      "text must be in the visible viewport",
    );
    assert.ok(measurements.width > 500);
    assert.equal(
      measurements.scrollTop,
      607,
      "Now keeps its scroll offset without snapping",
    );
    assert.ok(
      Math.abs(measurements.past.unused) < 1,
      "no unused strip below the past editor",
    );
    const { height, line, top } = measurements.past;
    const rows = Math.round(height / line);
    assert.ok(Math.abs(height - rows * line) < 1, "whole-row viewport height");
    assert.ok(
      Math.abs(top - (39 + 2 - rows) * line) < 1,
      "one context row after long selection",
    );
    const w = measurements.wrapped;
    assert.ok(
      Math.abs(
        w.top - (w.lastRow + 2 - Math.round(w.height / w.line)) * w.line,
      ) < 1,
      "wrapped selection has one context row",
    );
  }
}
