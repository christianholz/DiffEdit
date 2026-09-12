import { EditorView } from "@codemirror/view";

// Tauri adds a per-response CSP nonce to the shell's inline style. CodeMirror
// must reuse it for its generated layout rules; unsafe-inline does not suffice
// once the packaged application's policy contains a nonce.
export function editorStyleNonce() {
  return EditorView.cspNonce.of(
    document.querySelector<HTMLStyleElement>("style[nonce]")?.nonce ?? "",
  );
}
