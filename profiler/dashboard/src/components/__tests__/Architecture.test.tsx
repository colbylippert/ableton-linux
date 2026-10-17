/**
 * Architecture view: the diagrams render as accessible inline SVG, stay theme-driven
 * (classes only, and every class they use is styled by architecture.css), and the status
 * table lists every part.
 */
import { afterEach, describe, expect, it } from 'vitest';
import { STATUS_ROWS } from '../../architecture/status';
import ArchitectureView, { FIGURES } from '../../views/Architecture';
import { all, mount, text, type Mounted } from './harness';

/**
 * The stylesheet as text. Vitest turns every CSS import, `?raw` included, into "" while
 * `test.css` is false, and the project has no @types/node, so read the file through Node's
 * built-in module loader. The path is resolved with node:path because Vite rewrites
 * `new URL('…', import.meta.url)` into an asset URL.
 */
function readStylesheet(): string {
  const { process } = globalThis as unknown as { process: { getBuiltinModule(id: string): unknown } };
  const fs = process.getBuiltinModule('node:fs') as { readFileSync(path: string, encoding: 'utf8'): string };
  const path = process.getBuiltinModule('node:path') as { dirname(p: string): string; resolve(...parts: string[]): string };
  const url = process.getBuiltinModule('node:url') as { fileURLToPath(href: string): string };
  const here = path.dirname(url.fileURLToPath(import.meta.url));
  return fs.readFileSync(path.resolve(here, '../../architecture/architecture.css'), 'utf8');
}

describe('Architecture view', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders one captioned, labelled figure per diagram and the status table', () => {
    mounted = mount(<ArchitectureView />);
    const c = mounted.container;
    expect(text(c.querySelector('h2'))).toBe('Architecture');
    const figures = all(c, 'figure.arch-figure');
    expect(figures).toHaveLength(FIGURES.length);
    for (const figure of figures) {
      const svg = figure.querySelector('svg[role="img"]');
      expect(svg?.getAttribute('aria-label')?.length ?? 0).toBeGreaterThan(80);
      expect(text(figure.querySelector('figcaption')).length).toBeGreaterThan(80);
    }
    expect(all(c, '.arch-status tbody tr')).toHaveLength(STATUS_ROWS.length);
    expect(all(c, '.arch-status .chip')).toHaveLength(STATUS_ROWS.length);
  });

  it('gives every element a unique id (marker references stay unambiguous)', () => {
    mounted = mount(<ArchitectureView />);
    const ids = all(mounted.container, '[id]').map((el) => el.id);
    expect(ids.length).toBeGreaterThan(FIGURES.length);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('keeps the drawings theme-driven: no inline colour, style, script or foreign content', () => {
    for (const figure of FIGURES) {
      expect(figure.svg).not.toMatch(/\s(fill|stroke|style|color|opacity)="/i);
      expect(figure.svg).not.toMatch(/<(script|style|foreignObject)\b/i);
    }
  });

  it('styles every class the drawings use', () => {
    const css = readStylesheet();
    expect(css).toContain('.arch-svg');
    const used = new Set(FIGURES.flatMap((f) => Array.from(f.svg.matchAll(/class="([^"]+)"/g), (m) => (m[1] ?? '').split(/\s+/)).flat()));
    used.delete('arch-svg');
    const missing = Array.from(used).filter((name) => !new RegExp(`\\.arch-svg [^{]*\\.${name}(?![\\w-])`).test(css));
    expect(missing).toEqual([]);
  });
});
