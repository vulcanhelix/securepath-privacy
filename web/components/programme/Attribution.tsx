import * as React from 'react';

// W2-00 — FR-BRN-05 SecurePath attribution line. Rendered by the programme
// shell whenever the partner's active licence carries attribution_display
// (default true; unreadable licence ⇒ shown — see lib/programme-context.ts).

export function Attribution({ partnerName }: { partnerName?: string | null }) {
  return (
    <p className="sp-attr">
      Powered by <strong>SecurePath</strong>
      {partnerName ? <span className="muted"> · delivered by {partnerName}</span> : null}
    </p>
  );
}
