import * as React from 'react';

export function scoreTone(pct: number): 'pass' | 'warn' | 'fail' {
  return pct >= 75 ? 'pass' : pct >= 50 ? 'warn' : 'fail';
}

export function ScoreRing({ pct = 0, size = 96, label }: { pct?: number; size?: number; label?: React.ReactNode }) {
  const stroke = Math.max(6, Math.round(size / 13));
  const r = (size - stroke) / 2;
  const circ = 2 * Math.PI * r;
  const color = `var(--${scoreTone(pct)})`;
  return (
    <div className="sp-ring" style={{ width: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--inset)" strokeWidth={stroke} />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke={color}
          strokeWidth={stroke}
          strokeLinecap="round"
          strokeDasharray={circ}
          strokeDashoffset={circ * (1 - Math.min(100, Math.max(0, pct)) / 100)}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          style={{ transition: 'stroke-dashoffset 600ms var(--ease)' }}
        />
      </svg>
      <div className="sp-ring-val" style={{ fontSize: Math.round(size / 4.2) }}>
        {Math.round(pct)}
        <span className="sp-ring-pct">%</span>
      </div>
      {label ? <div className="sp-ring-label">{label}</div> : null}
    </div>
  );
}
