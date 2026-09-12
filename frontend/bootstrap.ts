import "./style.css";
import { invoke } from "@tauri-apps/api/core";

const root = document.getElementById("app")!;
root.inert = true;
// Restore the visible shell geometry before its first frame.
document.documentElement.style.setProperty(
  "--sidebar",
  `${Number(localStorage.getItem("sidebarWidth")) || 240}px`,
);
performance.mark("shell-ready");
// The static shell and its stylesheet exist before revealing the native window.
// Do not wait on rAF while the native window is hidden: WebKit may suspend it.
void invoke("show_ready", { shellMs: performance.now() })
  .then(() => {
    requestAnimationFrame(() =>
      setTimeout(async () => {
        const start = performance.now();
        try {
          await import("./main");
          root.inert = false;
          performance.mark("editor-ready");
          console.info("startup", {
            shellMs: performance.getEntriesByName("shell-ready")[0]?.startTime,
            editorSetupMs: performance.now() - start,
            readyMs: performance.now(),
          });
        } catch (error) {
          root.inert = false;
          const message = document.querySelector(".message");
          if (message)
            message.textContent = `Could not start the editor: ${String(error)}`;
          console.error(error);
        }
      }, 0),
    );
  })
  .catch(console.error);
