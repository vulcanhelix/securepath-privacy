import * as React from 'react';

export function Badge({
  tone = 'neutral',
  dot = false,
  children,
}: {
  tone?: 'neutral' | 'accent' | 'ink' | 'pass' | 'warn' | 'fail';
  dot?: boolean;
  children: React.ReactNode;
}) {
  return (
    <span className={`sp-badge sp-badge--${tone}`}>
      {dot ? <span className="sp-badge-dot" /> : null}
      {children}
    </span>
  );
}
