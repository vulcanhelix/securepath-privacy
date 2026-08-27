import * as React from 'react';
import { scoreTone } from './ScoreRing';

export function SectionBars({ sections = [] }: { sections: { name: string; pct: number }[] }) {
  return (
    <div className="sp-bars">
      {sections.map((sec, i) => (
        <div key={i} className="sp-bars-row">
          <span className="sp-bars-name">{sec.name}</span>
          <span className="sp-bars-track">
            <span
              className="sp-bars-fill"
              style={{ width: `${Math.min(100, Math.max(0, sec.pct))}%`, background: `var(--${scoreTone(sec.pct)})` }}
            />
          </span>
          <span className="sp-bars-val">{Math.round(sec.pct)}%</span>
        </div>
      ))}
    </div>
  );
}
