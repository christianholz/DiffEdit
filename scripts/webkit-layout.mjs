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
    import {EditorView, lineNumbers} from "@codemirror/view";
    import {editorStyleNonce} from "./frontend/editor-style";
    import {pastViewport, wholeRowScroll} from "./frontend/past-viewport";
    import {EditorSelection} from "@codemirror/state";
    const view = new EditorView({parent: document.querySelector('.now'), doc: 'Visible paragraph with content.\\n'.repeat(500),
      extensions: [lineNumbers(), EditorView.lineWrapping, ${withNonce ? "editorStyleNonce(), wholeRowScroll," : ""}]});
    const past = ${withNonce} ? new EditorView({parent: document.querySelector('.past'), doc: 'Past row with descenders pg.\\n'.repeat(100), extensions: [lineNumbers(), EditorView.lineWrapping, editorStyleNonce(), pastViewport]}) : null;
    setTimeout(() => {
      if (past) past.dispatch({effects: EditorView.scrollIntoView(EditorSelection.range(past.state.doc.line(30).from, past.state.doc.line(40).to))});
      const scroller = view.scrollDOM;
      const content = view.contentDOM.getBoundingClientRect();
      const gutter = document.querySelector('.cm-gutters').getBoundingClientRect();
      scroller.scrollTop = 607;
      setTimeout(() => { const result = {
        display: getComputedStyle(scroller).display, contentX: content.x, contentY: content.y,
        gutterRight: gutter.right, scrollTop: scroller.scrollTop, width: scroller.clientWidth, lineHeight: view.defaultLineHeight,
        past: past ? { unused: past.dom.parentElement.clientHeight - 5 - past.dom.getBoundingClientRect().height, height: past.scrollDOM.clientHeight, line: past.defaultLineHeight, top: past.scrollDOM.scrollTop, contentTop: past.contentDOM.getBoundingClientRect().top, row40: past.coordsAtPos(past.state.doc.line(40).from), block40: past.lineBlockAt(past.state.doc.line(40).from).top, cssLine: getComputedStyle(past.contentDOM).lineHeight } : null,
      };
      if (!past) { window.webkit.messageHandlers.result.postMessage(JSON.stringify(result)); return; }
      const wrapped = 'Words with descenders pg and more content. '.repeat(80);
      past.dispatch({changes: {from: 0, to: past.state.doc.length, insert: wrapped}});
      // Use the same selection policy inside one long wrapped source line.
      past.dispatch({effects: EditorView.scrollIntoView(EditorSelection.range(100, 2000))});
      setTimeout(() => {
        const end = past.coordsAtPos(1999);
        const lastRow = Math.floor((end.top - past.contentDOM.getBoundingClientRect().top + .5) / past.defaultLineHeight);
        result.wrapped = {lastRow, top: past.scrollDOM.scrollTop, line: past.defaultLineHeight, height: past.scrollDOM.clientHeight};
        window.webkit.messageHandlers.result.postMessage(JSON.stringify(result));
      }, 100);
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
    assert.ok(measurements.contentX >= measurements.gutterRight);
    assert.ok(
      measurements.contentY < 150,
      "text must be in the visible viewport",
    );
    assert.ok(measurements.width > 500);
    assert.ok(
      Math.abs(
        measurements.scrollTop / measurements.lineHeight -
          Math.round(measurements.scrollTop / measurements.lineHeight),
      ) < 0.05,
      "now pane starts on a full visual row",
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
