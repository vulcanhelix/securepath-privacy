import * as React from 'react';
import { Badge } from './Badge';

// Gate panel — card with a 3px left accent stripe (--pass once passed), title + status
// badge, the sign-off action on the right, one explanatory paragraph.
export function GatePanel({
  title,
  passed,
  badges,
  action,
  children,
}: {
  title: React.ReactNode;
  passed?: boolean;
  badges?: React.ReactNode;
  action?: React.ReactNode;
  children?: React.ReactNode;
}) {
  return (
    <section
      className="sp-card sp-card--light"
      style={{ borderLeft: `3px solid var(--${passed ? 'pass' : 'accent'})`, marginBottom: 24 }}
    >
      <div style={{ padding: '20px 28px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          <strong style={{ fontSize: 'var(--fs-body)' }}>{title}</strong>
          {passed ? <Badge tone="pass" dot>Passed</Badge> : null}
          {badges}
          <span style={{ flex: 1 }} />
          {action}
        </div>
        {children ? (
          <p className="muted" style={{ margin: '10px 0 0', fontSize: 'var(--fs-sm)' }}>{children}</p>
        ) : null}
      </div>
    </section>
  );
}
