import * as React from 'react';

export function StatusDot({ tone = 'neutral', label }: { tone?: 'pass' | 'warn' | 'fail' | 'neutral'; label?: React.ReactNode }) {
  return (
    <span className={`sp-dot sp-dot--${tone}`}>
      <span className="sp-dot-i" />
      {label}
    </span>
  );
}
