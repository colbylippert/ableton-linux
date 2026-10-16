/**
 * Minimal render harness for component tests: React 18 `act` + `react-dom/client`, no
 * testing-library (DESIGN.md §10). Not a test file itself (no `.test.` in the name).
 */
import { act, type ReactElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

export interface Mounted {
  container: HTMLDivElement;
  root: Root;
  rerender: (element: ReactElement) => void;
  unmount: () => void;
}

export function mount(element: ReactElement): Mounted {
  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);
  act(() => root.render(element));
  return {
    container,
    root,
    rerender: (next) => act(() => root.render(next)),
    unmount: () => {
      act(() => root.unmount());
      container.remove();
    },
  };
}

export function click(element: Element | null | undefined): void {
  if (!element) throw new Error('click: target not found');
  act(() => {
    (element as HTMLElement).click();
  });
}

/** Changes a controlled <select> the way a user would (bypasses React's value tracker). */
export function choose(select: HTMLSelectElement | null | undefined, value: string): void {
  if (!select) throw new Error('choose: select not found');
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set;
    if (!setter) throw new Error('choose: no value setter');
    setter.call(select, value);
    select.dispatchEvent(new Event('change', { bubbles: true }));
  });
}

export function text(element: Element | null | undefined): string {
  return (element?.textContent ?? '').replace(/\s+/g, ' ').trim();
}

export function all<T extends Element = Element>(parent: ParentNode, selector: string): T[] {
  return Array.from(parent.querySelectorAll<T>(selector));
}

export function byText<T extends HTMLElement = HTMLElement>(parent: ParentNode, selector: string, label: string): T | undefined {
  return all<T>(parent, selector).find((el) => text(el) === label);
}
