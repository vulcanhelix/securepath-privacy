'use client';
import * as React from 'react';
import { Icon } from './Icon';
import type { Column } from './DataTable';

// W2-00 kit — sortable variant of DataTable (same .sp-table markup; sorting
// is client-side so a page can offer FR-PCN-02-style sort without a round
// trip). `rows[i].values[j]` supplies the sort key for column j; when absent
// the cell's text content is used.

export interface SortableRow {
  cells: React.ReactNode[];
  values?: (string | number | null | undefined)[];
}

function cellText(n: React.ReactNode): string {
  if (n == null || typeof n === 'boolean') return '';
  if (typeof n === 'string' || typeof n === 'number') return String(n);
  if (Array.isArray(n)) return n.map(cellText).join(' ');
  if (React.isValidElement(n)) return cellText((n.props as { children?: React.ReactNode }).children);
  return '';
}

export function SortableTable({
  columns,
  rows,
  initialSort,
  initialDir = 'asc',
}: {
  columns: (Column & { sortable?: boolean })[];
  rows: SortableRow[];
  initialSort?: number;
  initialDir?: 'asc' | 'desc';
}) {
  const [sort, setSort] = React.useState<number | null>(initialSort ?? null);
  const [dir, setDir] = React.useState<'asc' | 'desc'>(initialDir);

  const sorted = React.useMemo(() => {
    if (sort == null) return rows;
    const key = (r: SortableRow) => r.values?.[sort] ?? cellText(r.cells[sort]);
    return [...rows].sort((a, b) => {
      const av = key(a);
      const bv = key(b);
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      const cmp =
        typeof av === 'number' && typeof bv === 'number'
          ? av - bv
          : String(av).localeCompare(String(bv), undefined, { numeric: true });
      return dir === 'asc' ? cmp : -cmp;
    });
  }, [rows, sort, dir]);

  return (
    <div className="sp-table-scroll">
      <table className="sp-table">
        <thead>
          <tr>
            {columns.map((c, i) => (
              <th key={i} style={c.align ? { textAlign: c.align } : undefined}>
                {c.sortable === false ? (
                  c.label
                ) : (
                  <button
                    type="button"
                    className="sp-thsort"
                    onClick={() => {
                      if (sort === i) setDir(dir === 'asc' ? 'desc' : 'asc');
                      else {
                        setSort(i);
                        setDir('asc');
                      }
                    }}
                  >
                    {c.label}
                    {sort === i ? (
                      <Icon name={dir === 'asc' ? 'arrow-up' : 'arrow-down'} size={11} />
                    ) : (
                      <Icon name="arrow-up-down" size={11} className="sp-thsort-dim" />
                    )}
                  </button>
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.map((r, i) => (
            <tr key={i}>
              {r.cells.map((cell, j) => (
                <td key={j} style={columns[j]?.align ? { textAlign: columns[j].align } : undefined}>
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
