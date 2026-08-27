import * as React from 'react';
import Link from 'next/link';

export function PageHeader({
  title,
  meta,
  actions,
  back,
  backHref,
  eyebrow,
}: {
  title: React.ReactNode;
  meta?: React.ReactNode;
  actions?: React.ReactNode;
  back?: string;
  backHref?: string;
  eyebrow?: React.ReactNode;
}) {
  return (
    <div className="sp-pagehd">
      <div>
        {back && backHref ? (
          <Link className="sp-pagehd-back" href={backHref}>
            &larr; {back}
          </Link>
        ) : null}
        {eyebrow ? <div className="sp-pagehd-eyebrow">{eyebrow}</div> : null}
        <h1 className="sp-pagehd-title">{title}</h1>
        {meta ? <div className="sp-pagehd-meta">{meta}</div> : null}
      </div>
      <div className="sp-pagehd-actions">{actions}</div>
    </div>
  );
}
