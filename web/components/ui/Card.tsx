import * as React from 'react';

export function Card({
  title,
  action,
  pad = 28,
  tone = 'light',
  children,
  style,
}: {
  title?: React.ReactNode;
  action?: React.ReactNode;
  pad?: number;
  tone?: 'light' | 'plain' | 'dark';
  children: React.ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <section className={`sp-card sp-card--${tone}`} style={style}>
      {title || action ? (
        <header className="sp-card-hd" style={{ padding: `18px ${pad}px` }}>
          <h2 className="sp-card-title">{title}</h2>
          <div>{action}</div>
        </header>
      ) : null}
      <div style={{ padding: pad }}>{children}</div>
    </section>
  );
}
