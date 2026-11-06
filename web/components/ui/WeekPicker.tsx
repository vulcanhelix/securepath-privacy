'use client';
import * as React from 'react';
import { Icon } from './Icon';

// W2-00 kit — programme week picker (spec §9.1: week 1 starts on the
// programme's Monday; screens 04/09 navigate by week). Controlled: the page
// owns the selected week (usually via a ?week= search param).

export function WeekPicker({
  week,
  totalWeeks,
  onChange,
  label,
}: {
  week: number;
  totalWeeks?: number | null;
  onChange: (week: number) => void;
  label?: string;
}) {
  const max = totalWeeks ?? Number.MAX_SAFE_INTEGER;
  const clamp = (w: number) => Math.min(Math.max(1, w), max);
  return (
    <span className="sp-wpick">
      <button
        type="button"
        className="sp-btn sp-btn--ghost sp-btn--sm"
        disabled={week <= 1}
        onClick={() => onChange(clamp(week - 1))}
        aria-label="Previous week"
      >
        <Icon name="chevron-left" size={14} />
      </button>
      <span className="sp-wpick-cur">
        {label ?? 'Week'}{' '}
        <input
          className="sp-wpick-input"
          type="number"
          min={1}
          max={totalWeeks ?? undefined}
          value={week}
          onChange={(e) => {
            const w = parseInt(e.target.value, 10);
            if (!Number.isNaN(w)) onChange(clamp(w));
          }}
          aria-label="Week number"
        />
        {totalWeeks ? <span className="muted"> / {totalWeeks}</span> : null}
      </span>
      <button
        type="button"
        className="sp-btn sp-btn--ghost sp-btn--sm"
        disabled={week >= max}
        onClick={() => onChange(clamp(week + 1))}
        aria-label="Next week"
      >
        <Icon name="chevron-right" size={14} />
      </button>
    </span>
  );
}
