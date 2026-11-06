import * as React from 'react';
import { Badge } from './Badge';

// W2-00 kit — generic status pill over the programme-world status
// vocabularies (activities §6.2, register items, reports FR-RPT-04,
// maintenance instances, operational records, programmes).
// Pass `map` to override tones for a specific surface.

type Tone = 'neutral' | 'accent' | 'ink' | 'pass' | 'warn' | 'fail';

const DEFAULT_TONES: Record<string, Tone> = {
  // activities / generic lifecycle
  'not started': 'neutral',
  'in progress': 'accent',
  'at risk': 'warn',
  blocked: 'fail',
  deferred: 'neutral',
  complete: 'pass',
  // register items
  open: 'warn',
  closed: 'pass',
  // programme + report workflow (FR-RPT-04)
  implementation: 'accent',
  maintenance: 'pass',
  draft: 'neutral',
  inputs_complete: 'accent',
  ao_review: 'warn',
  signed: 'pass',
  issued: 'ink',
  // operational records
  'awaiting decision': 'warn',
  reported: 'accent',
  resolved: 'pass',
  // generic
  pending: 'warn',
  overdue: 'fail',
  suspended: 'fail',
  active: 'pass',
};

export function statusTone(status: string | null | undefined): Tone {
  return DEFAULT_TONES[(status ?? '').toLowerCase()] ?? 'neutral';
}

export function StatusPill({
  status,
  label,
  map,
  empty = '—',
}: {
  status: string | null | undefined;
  label?: React.ReactNode;
  map?: Record<string, Tone>;
  empty?: React.ReactNode;
}) {
  if (status == null || status === '') return <>{empty}</>;
  const tone = map?.[status.toLowerCase()] ?? statusTone(status);
  return (
    <Badge tone={tone} dot>
      {label ?? status}
    </Badge>
  );
}
