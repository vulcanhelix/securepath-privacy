import * as React from 'react';

const LEVELS = [
  { key: 'critical', label: 'Critical', color: 'var(--fail)' },
  { key: 'high', label: 'High', color: 'var(--risk-high)' },
  { key: 'medium', label: 'Medium', color: 'var(--warn)' },
  { key: 'low', label: 'Low', color: 'var(--pass)' },
] as const;

export function RiskStrip({ counts = {} }: { counts: Partial<Record<'critical' | 'high' | 'medium' | 'low', number>> }) {
  const total = LEVELS.reduce((n, l) => n + (counts[l.key] || 0), 0) || 1;
  return (
    <div className="sp-risk">
      <div className="sp-risk-strip">
        {LEVELS.map((l) =>
          (counts[l.key] || 0) > 0 ? (
            <span key={l.key} style={{ flex: (counts[l.key] || 0) / total, background: l.color }} title={`${l.label}: ${counts[l.key]}`} />
          ) : null
        )}
      </div>
      <div className="sp-risk-legend">
        {LEVELS.map((l) => (
          <span key={l.key} className="sp-risk-item">
            <span className="sp-risk-dot" style={{ background: l.color }} />
            {l.label} <strong>{counts[l.key] || 0}</strong>
          </span>
        ))}
      </div>
    </div>
  );
}
