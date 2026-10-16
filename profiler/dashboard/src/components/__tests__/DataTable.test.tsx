import { afterEach, describe, expect, it, vi } from 'vitest';
import DataTable, { cellText, type Column } from '../DataTable';
import { all, byText, click, mount, text, type Mounted } from './harness';

interface Row {
  id: string;
  name: string;
  value: number | null;
}

const rows: Row[] = [
  { id: 'a', name: 'bravo', value: 3 },
  { id: 'b', name: 'alpha', value: null },
  { id: 'c', name: 'Charlie', value: 1 },
  { id: 'd', name: 'delta', value: 2 },
];

const columns: Column<Row>[] = [
  { key: 'name', header: 'Name' },
  { key: 'value', header: 'Value', numeric: true },
];

function firstCells(container: ParentNode): string[] {
  return all(container, 'tbody tr').map((tr) => text(tr.querySelector('td:not(.col-select)')));
}

describe('DataTable', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders every row with nulls as "—" and a caption', () => {
    mounted = mount(<DataTable caption="Fixture rows" columns={columns} rows={rows} rowKey={(r) => r.id} />);
    expect(text(mounted.container.querySelector('caption'))).toBe('Fixture rows');
    expect(all(mounted.container, 'tbody tr')).toHaveLength(4);
    const valueCells = all(mounted.container, 'tbody td.num').map(text);
    expect(valueCells).toEqual(['3', '—', '1', '2']);
    expect(cellText(1234.5)).toBe('1,234.5');
    expect(cellText(undefined)).toBe('—');
  });

  it('sorts numeric columns both ways with nulls last, and string columns case-insensitively', () => {
    mounted = mount(<DataTable caption="Sort" columns={columns} rows={rows} rowKey={(r) => r.id} />);
    const valueHeader = byText<HTMLButtonElement>(mounted.container, 'th button', 'Value');
    click(valueHeader);
    expect(firstCells(mounted.container)).toEqual(['Charlie', 'delta', 'bravo', 'alpha']);
    expect(mounted.container.querySelectorAll('th')[1]?.getAttribute('aria-sort')).toBe('ascending');
    click(valueHeader);
    expect(firstCells(mounted.container)).toEqual(['bravo', 'delta', 'Charlie', 'alpha']);
    expect(mounted.container.querySelectorAll('th')[1]?.getAttribute('aria-sort')).toBe('descending');

    click(byText<HTMLButtonElement>(mounted.container, 'th button', 'Name'));
    expect(firstCells(mounted.container)).toEqual(['alpha', 'bravo', 'Charlie', 'delta']);
  });

  it('honours defaultSort and custom sortValue / render', () => {
    const custom: Column<Row>[] = [{ key: 'name', header: 'Name', render: (r) => r.name.toUpperCase(), sortValue: (r) => r.name.length }];
    mounted = mount(<DataTable caption="Custom" columns={custom} rows={rows} rowKey={(r) => r.id} defaultSort={{ key: 'name', dir: 'desc' }} />);
    expect(firstCells(mounted.container)).toEqual(['CHARLIE', 'BRAVO', 'ALPHA', 'DELTA']);
  });

  it('caps the selection (oldest dropped first) and reports the full selection', () => {
    const onChange = vi.fn();
    const Wrapper = ({ selected }: { selected: string[] }) => (
      <DataTable caption="Select" columns={columns} rows={rows} rowKey={(r) => r.id} selectable={{ selected, max: 2, onChange }} />
    );
    mounted = mount(<Wrapper selected={[]} />);
    const boxes = () => all<HTMLInputElement>(mounted!.container, 'input[type="checkbox"]');
    click(boxes()[0]);
    expect(onChange).toHaveBeenLastCalledWith(['a']);
    mounted.rerender(<Wrapper selected={['a']} />);
    click(boxes()[1]);
    expect(onChange).toHaveBeenLastCalledWith(['a', 'b']);
    mounted.rerender(<Wrapper selected={['a', 'b']} />);
    expect(all(mounted.container, 'tr.is-selected')).toHaveLength(2);
    click(boxes()[2]);
    expect(onChange).toHaveBeenLastCalledWith(['b', 'c']);
    mounted.rerender(<Wrapper selected={['b', 'c']} />);
    click(boxes()[1]);
    expect(onChange).toHaveBeenLastCalledWith(['c']);
  });

  it('shows the empty message when there are no rows', () => {
    mounted = mount(<DataTable caption="Empty" columns={columns} rows={[]} rowKey={(r) => r.id} emptyMessage="Nothing here" />);
    expect(text(mounted.container.querySelector('tbody'))).toBe('Nothing here');
  });
});
