import * as React from 'react';
import { Badge } from './Badge';

// W2-00 kit — evidence-chain status (spec §6.2 evidence_items:
// review_stage verification → acceptance → decided, forward-only; outcome
// recorded at acceptance). FR-EVD-06 mints the EV ref on accept.

export function EvidenceChip({
  stage,
  outcome,
  evidenceRef,
}: {
  stage: 'verification' | 'acceptance' | 'decided' | string | null | undefined;
  outcome?: 'closes_finding' | 'partly_supports' | 'kpi_evidence' | string | null;
  evidenceRef?: string | null;
}) {
  const label =
    stage === 'decided'
      ? outcome === 'closes_finding'
        ? 'Accepted — closes finding'
        : outcome === 'partly_supports'
          ? 'Accepted — partly supports'
          : outcome === 'kpi_evidence'
            ? 'Accepted — KPI evidence'
            : 'Decided'
      : stage === 'acceptance'
        ? 'Awaiting acceptance'
        : stage === 'verification'
          ? 'In verification'
          : stage ?? 'Uploaded';
  const tone =
    stage === 'decided' ? 'pass' : stage === 'acceptance' ? 'warn' : stage === 'verification' ? 'accent' : 'neutral';
  return (
    <Badge tone={tone} dot>
      {evidenceRef ? `${evidenceRef} · ` : ''}
      {label}
    </Badge>
  );
}
