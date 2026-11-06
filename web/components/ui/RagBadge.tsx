import * as React from 'react';
import { Badge } from './Badge';

// W2-00 kit — spec §9 RAG vocabulary. Semantic colours are fixed, never
// whitelabelled (globals.css: --pass/--warn/--fail are not the accent).
export type Rag = 'Green' | 'Amber' | 'Red' | 'Not due' | 'Complete' | string | null | undefined;

export function ragTone(rag: Rag): 'pass' | 'warn' | 'fail' | 'ink' | 'neutral' {
  switch (rag) {
    case 'Green':
    case 'Complete':
      return 'pass';
    case 'Amber':
      return 'warn';
    case 'Red':
      return 'fail';
    case 'Closed':
    case 'Issued':
      return 'ink';
    default:
      return 'neutral';
  }
}

export function RagBadge({ rag, empty = '—' }: { rag: Rag; empty?: React.ReactNode }) {
  if (rag == null || rag === '') return <>{empty}</>;
  return (
    <Badge tone={ragTone(rag)} dot>
      {rag}
    </Badge>
  );
}
