const cleanup = new WeakMap<HTMLElement, () => void>();

export function clearVirtualRows(container: HTMLElement) {
  cleanup.get(container)?.();
  cleanup.delete(container);
  container.replaceChildren();
}

/** Keep mounted rows stable, including a focused row outside the viewport. */
export function virtualRows(
  container: HTMLElement,
  count: number,
  height: number,
  row: (index: number) => HTMLElement,
  removed: (index: number) => void,
) {
  clearVirtualRows(container);
  const content = container.ownerDocument.createElement("div");
  content.style.cssText = `position:relative;height:${count * height}px;min-width:100%`;
  container.replaceChildren(content);
  const mounted = new Map<number, HTMLElement>();
  const mount = (i: number) => {
    let element = mounted.get(i);
    if (!element) {
      element = row(i);
      element.dataset.virtualIndex = String(i);
      element.style.position = "absolute";
      element.style.top = `${i * height}px`;
      element.style.height = `${height}px`;
      element.style.minWidth = "100%";
      mounted.set(i, element);
      // Preserve document order for native tab navigation.
      const next = [...mounted]
        .filter(([n]) => n > i)
        .sort(([a], [b]) => a - b)[0]?.[1];
      content.insertBefore(element, next ?? null);
    }
    return element;
  };
  const render = () => {
    const start = Math.max(0, Math.floor(container.scrollTop / height) - 6);
    const end = Math.min(
      count,
      start + Math.ceil((container.clientHeight || 440) / height) + 12,
    );
    for (const [i, element] of mounted) {
      if (
        (i < start || i >= end) &&
        !element.contains(container.ownerDocument.activeElement)
      ) {
        element.remove();
        mounted.delete(i);
        removed(i);
      }
    }
    for (let i = start; i < end; i++) mount(i);
  };
  const navigate = (event: KeyboardEvent) => {
    const target = event.target;
    if (!(target instanceof HTMLElement)) return;
    const current = target.closest<HTMLElement>("[data-virtual-index]");
    if (!current) return;
    let i = Number(current.dataset.virtualIndex);
    let step = 1;
    switch (event.key) {
      case "ArrowUp":
        step = -1;
        i--;
        break;
      case "ArrowDown":
        i++;
        break;
      case "Home":
        i = 0;
        break;
      case "End":
        i = count - 1;
        step = -1;
        break;
      case "Tab":
        step = event.shiftKey ? -1 : 1;
        i += step;
        break;
      default:
        return;
    }
    while (i >= 0 && i < count) {
      const input = mount(i).querySelector<HTMLInputElement>(
        "input:not(:disabled)",
      );
      if (input) {
        event.preventDefault();
        container.scrollTop = Math.max(
          0,
          i * height - container.clientHeight / 2,
        );
        input.focus({ preventScroll: true });
        render();
        return;
      }
      i += step;
    }
    render();
  };
  container.addEventListener("scroll", render, { passive: true });
  container.addEventListener("keydown", navigate);
  const observer = new ResizeObserver(render);
  observer.observe(container);
  cleanup.set(container, () => {
    container.removeEventListener("scroll", render);
    container.removeEventListener("keydown", navigate);
    observer.disconnect();
  });
  render();
}
