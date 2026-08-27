import * as React from 'react';
import { ScoreRing } from './ScoreRing';

export function ScorePanel({
  pct = 0,
  rating = 'In Progress',
  completionPct = 0,
  criticalGaps = 0,
}: {
  pct?: number;
  rating?: string;
  completionPct?: number;
  criticalGaps?: number;
}) {
  return (
    <div className="sp-scorep">
      <ScoreRing pct={pct} size={84} />
      <div className="sp-scorep-meta">
        <div className="sp-scorep-rating">{rating}</div>
        <div className="sp-scorep-line">{Math.round(completionPct)}% complete</div>
        {criticalGaps > 0 ? (
          <div className="sp-scorep-crit">
            {criticalGaps} critical gap{criticalGaps === 1 ? '' : 's'}
          </div>
        ) : null}
      </div>
    </div>
  );
}
