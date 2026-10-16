/**
 * Minimal React 18 mount helper for the D3 smoke tests (react-dom/client + act, no
 * testing-library, same pattern as src/App.test.tsx). Not a test file itself.
 */
import { act, type ReactElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

export interface Mounted {
  container: HTMLDivElement;
  root: Root;
  rerender: (element: ReactElement) => void;
  unmount: () => void;
  text: () => string;
  $: <T extends Element = HTMLElement>(selector: string) => T | null;
  $$: <T extends Element = HTMLElement>(selector: string) => T[];
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
    text: () => container.textContent ?? '',
    $: <T extends Element = HTMLElement>(selector: string) => container.querySelector<T>(selector),
    $$: <T extends Element = HTMLElement>(selector: string) => Array.from(container.querySelectorAll<T>(selector)),
  };
}

export function click(el: Element | null | undefined): void {
  if (!el) throw new Error('click: element not found');
  act(() => {
    (el as HTMLElement).click();
  });
}

export function focusIn(el: Element | null | undefined): void {
  if (!el) throw new Error('focusIn: element not found');
  act(() => {
    el.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
  });
}

export function change(el: HTMLSelectElement | HTMLInputElement | null | undefined, value: string): void {
  if (!el) throw new Error('change: element not found');
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
    setter?.call(el, value);
    el.dispatchEvent(new Event('change', { bubbles: true }));
  });
}
