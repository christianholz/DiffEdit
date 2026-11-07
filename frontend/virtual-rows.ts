const cleanup = new WeakMap<HTMLElement, () => void>();

export function clearVirtualRows(container: HTMLElement) {
  cleanup.get(container)?.();
  cleanup.delete(container);
  container.replaceChildren();
}

/** Fixed visual rows keep large staging diffs out of the DOM. */
export function virtualRows(
  container: HTMLElement,
  count: number,
  height: number,
  row: (index: number) => HTMLElement,
  beforeRender: () => void,
) {
  clearVirtualRows(container);
  const content = container.ownerDocument.createElement("div");
  content.style.cssText = `position:relative;height:${count * height}px;min-width:100%`;
  container.replaceChildren(content);
  const render = () => {
    beforeRender();
    const start = Math.max(0, Math.floor(container.scrollTop / height) - 6);
    const end = Math.min(
      count,
      start + Math.ceil((container.clientHeight || 440) / height) + 12,
    );
    const fragment = container.ownerDocument.createDocumentFragment();
    for (let i = start; i < end; i++) {
      const element = row(i);
      element.style.position = "absolute";
      element.style.top = `${i * height}px`;
      element.style.height = `${height}px`;
      element.style.minWidth = "100%";
      fragment.append(element);
    }
    content.replaceChildren(fragment);
  };
  container.addEventListener("scroll", render, { passive: true });
  const observer = new ResizeObserver(render);
  observer.observe(container);
  cleanup.set(container, () => {
    container.removeEventListener("scroll", render);
    observer.disconnect();
  });
  render();
}
