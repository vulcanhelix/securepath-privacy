import * as React from 'react';
import { Badge } from './Badge';

// W2-00 kit — compact "Week n / m" display (spec §9.1 programme weeks).

export function WeekBadge({ week, total }: { week: number | null | undefined; total?: number | null }) {
  return (
    <Badge tone="accent" dot>
      Week {week ?? '—'}
      {total ? <span className="muted"> / {total}</span> : null}
    </Badge>
  );
}
