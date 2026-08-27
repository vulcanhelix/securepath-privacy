'use client';
import { useState } from 'react';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { DataTable } from '@/components/ui/DataTable';
import { StatusDot } from '@/components/ui/StatusDot';
import { Checkbox } from '@/components/ui/forms';
import { DocPreview } from '@/components/ui/DocPreview';

type Slot = {
  id: string; name: string; description: string | null; category: string; required: boolean;
  fills: { id: string; name: string; version: number; replaces: string | null }[];
};

export default function GapMap({ slots }: { slots: Slot[] }) {
  const [gapsOnly, setGapsOnly] = useState(false);
  const shown = gapsOnly ? slots.filter(s => s.required && s.fills.length === 0) : slots;

  return (
    <Card
      title="Gap map"
      pad={0}
      style={{ marginTop: 24 }}
      action={<Checkbox label="Gaps only" checked={gapsOnly} onChange={e => setGapsOnly(e.target.checked)} />}
    >
      <DataTable
        columns={[{ label: 'Expected document' }, { label: 'Category' }, { label: 'Status' }, { label: 'Satisfied by' }]}
        rows={shown.map(s => [
          <span key="n">
            <span style={{ color: 'var(--text)', fontWeight: 500 }}>{s.name}</span>
            {!s.required && <span className="muted"> (optional)</span>}
            {s.description ? (
              <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-xs)' }}>{s.description}</span>
            ) : null}
          </span>,
          <Badge key="c">{s.category}</Badge>,
          s.fills.length > 0
            ? <StatusDot key="s" tone="pass" label="In place" />
            : s.required
              ? <StatusDot key="s" tone="fail" label="Gap" />
              : <StatusDot key="s" tone="neutral" label="—" />,
          <span key="f">
            {s.fills.map(d => (
              <span key={d.id}>
                <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <a href={`/api/documents/${d.id}`} style={{ color: 'var(--text-2)' }}>{d.name}</a>
                  {d.version > 1 && <span className="mono" style={{ fontSize: 'var(--fs-label)', color: 'var(--faint)' }}>v{d.version}</span>}
                  <DocPreview docId={d.id} filename={d.name} />
                </span>
                {d.replaces && (
                  <span className="muted" style={{ display: 'block', fontSize: 'var(--fs-label)' }}>replaces {d.replaces}</span>
                )}
              </span>
            ))}
          </span>,
        ])}
      />
    </Card>
  );
}
