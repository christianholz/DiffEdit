import "./style.css";
import { invoke } from "@tauri-apps/api/core";

async function start() {
  // Initialize immediately, without waiting for a frame in the hidden WebView.
  // The native folder picker remains usable while the editor loads.
  try {
    const { startWindow } = await import("./main");
    await startWindow();
  } catch (error) {
    document.querySelector(".message")!.textContent =
      `Could not open the editor: ${String(error)}`;
    console.error(error);
  }
  await invoke("show_ready", { shellMs: performance.now() });
}

void start().catch(console.error);
