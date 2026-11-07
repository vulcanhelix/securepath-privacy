'use client';

import { Icon } from '@/components/ui/Icon';

// W3-03 — the only client code on the print route: opens the browser print
// dialog, whose "Save as PDF" destination is the PDF export (no server-side
// PDF renderer, no new dependency).
export function PrintButton() {
  return (
    <button type="button" className="sp-btn sp-btn--primary sp-btn--sm" onClick={() => window.print()}>
      <Icon name="printer" size={14} />
      Print / Save as PDF
    </button>
  );
}
