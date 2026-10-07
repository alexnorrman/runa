/** A tiny DOM builder. No framework: the plugin UI is small and renders a few regions. */

type Child = Node | string | number | false | null | undefined | Child[];
type Attrs = {
  [name: string]: string | number | boolean | undefined | null | EventListener | ((event: never) => void);
};

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs | null = null, ...children: Child[]): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  if (attrs) {
    for (const [name, value] of Object.entries(attrs)) {
      if (value === undefined || value === null || value === false) continue;
      if (name.startsWith("on") && typeof value === "function") {
        element.addEventListener(name.slice(2).toLowerCase(), value as EventListener);
      } else if (name === "class") {
        element.className = String(value);
      } else if (name === "value" && "value" in element) {
        (element as HTMLInputElement).value = String(value);
      } else if (value === true) {
        element.setAttribute(name, "");
      } else {
        element.setAttribute(name, String(value));
      }
    }
  }
  append(element, children);
  return element;
}

function append(parent: Node, children: Child[]): void {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    if (Array.isArray(child)) append(parent, child);
    else if (child instanceof Node) parent.appendChild(child);
    else parent.appendChild(document.createTextNode(String(child)));
  }
}

export function replaceChildren(parent: Element, ...children: Child[]): void {
  while (parent.firstChild) parent.removeChild(parent.firstChild);
  append(parent, children);
}

const SVG_NS = "http://www.w3.org/2000/svg";

/** 16px line icons drawn on a 16 grid, stroke = currentColor. */
const ICONS: Record<string, string[]> = {
  refresh: ["M13.5 8a5.5 5.5 0 1 1-1.6-3.9", "M13.5 2.5v3h-3"],
  settings: [
    "M8 10.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4Z",
    "M13 8c0-.4 0-.7-.1-1l1.3-1-1.3-2.2-1.5.6c-.5-.4-1-.7-1.7-.9L9.5 2h-3l-.3 1.5c-.6.2-1.2.5-1.7.9L3 3.8 1.8 6l1.3 1a5 5 0 0 0 0 2l-1.3 1L3 12.2l1.5-.6c.5.4 1.1.7 1.7.9l.3 1.5h3l.3-1.5c.6-.2 1.2-.5 1.7-.9l1.5.6 1.3-2.2-1.3-1c.1-.3.1-.6.1-1Z",
  ],
  back: ["M10 3.5 5.5 8l4.5 4.5"],
  close: ["M4 4l8 8", "M12 4l-8 8"],
  link: ["M6.5 9.5l3-3", "M7 4.5l1.2-1.2a2.8 2.8 0 0 1 4 4L11 8.5", "M9 11.5l-1.2 1.2a2.8 2.8 0 0 1-4-4L5 7.5"],
  search: ["M7 12a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z", "M10.7 10.7 14 14"],
  arrowUp: ["M8 13V3", "M4 7l4-4 4 4"],
  arrowDown: ["M8 3v10", "M4 9l4 4 4-4"],
  copy: ["M5.5 5.5h7v7h-7z", "M3.5 10.5v-7h7"],
  check: ["M3.5 8.5 6.5 11.5 12.5 4.5"],
  file: ["M4 2h5.5L12 4.5V14H4z", "M9.5 2v2.5H12"],
};

export function icon(name: keyof typeof ICONS | string, size = 16): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("fill", "none");
  svg.setAttribute("aria-hidden", "true");
  svg.classList.add("icon");
  for (const d of ICONS[name] ?? []) {
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", d);
    path.setAttribute("stroke", "currentColor");
    path.setAttribute("stroke-width", "1.3");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    svg.appendChild(path);
  }
  return svg;
}

/** The Runa mark: a single angular glyph. */
export function mark(size = 18): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("viewBox", "0 0 18 18");
  svg.setAttribute("aria-hidden", "true");
  svg.classList.add("mark");
  const rect = document.createElementNS(SVG_NS, "rect");
  rect.setAttribute("width", "18");
  rect.setAttribute("height", "18");
  rect.setAttribute("rx", "5");
  rect.setAttribute("fill", "#5E6AD2");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", "M6.5 13.5V4.5l5 3.2-5 3.2 5 2.6");
  path.setAttribute("stroke", "#fff");
  path.setAttribute("stroke-width", "1.6");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  path.setAttribute("fill", "none");
  svg.append(rect, path);
  return svg;
}
