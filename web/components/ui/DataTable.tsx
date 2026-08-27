import * as React from 'react';

export type Column = { label: React.ReactNode; align?: 'left' | 'right' | 'center' };

export function DataTable({ columns = [], rows = [] }: { columns: Column[]; rows: React.ReactNode[][] }) {
  return (
    <div className="sp-table-scroll">
      <table className="sp-table">
        <thead>
          <tr>
            {columns.map((c, i) => (
              <th key={i} style={c.align ? { textAlign: c.align } : undefined}>
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i}>
              {r.map((cell, j) => (
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
