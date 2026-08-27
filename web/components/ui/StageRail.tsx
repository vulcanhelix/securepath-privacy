import * as React from 'react';
import Link from 'next/link';
import { Icon } from './Icon';

export const STAGES = [
  { n: 0, label: 'Setup', slug: '' },
  { n: 1, label: 'Assessment', slug: 'assessment' },
  { n: 2, label: 'Documents', slug: 'documents' },
  { n: 3, label: 'Policies', slug: 'policies' },
  { n: 4, label: 'Manual', slug: 'manual' },
  { n: 5, label: 'Implementation', slug: 'tasks' },
  { n: 6, label: 'Report', slug: 'report' },
] as const;

// gate sits after this stage index
const GATES = [
  { g: 1, after: 1 },
  { g: 2, after: 3 },
  { g: 3, after: 4 },
  { g: 4, after: 5 },
] as const;

function gateState(after: number, stage: number): 'passed' | 'open' | 'locked' {
  return stage > after ? 'passed' : stage === after ? 'open' : 'locked';
}

export function StageRail({
  stage,
  hrefFor,
}: {
  stage: number;
  /** builds the link target for a stage node; return null for no link */
  hrefFor: (s: (typeof STAGES)[number]) => string | null;
}) {
  return (
    <div className="sp-rail">
      {STAGES.map((s, i) => {
        const state = s.n < stage ? 'done' : s.n === stage ? 'current' : 'future';
        const href = hrefFor(s);
        const gate = GATES.find((g) => g.after === s.n);
        const node = (
          <div className={`sp-rail-node sp-rail-node--${state}`}>
            <span className="sp-rail-dot">
              {state === 'done' ? <Icon name="check" size={14} /> : <span className="mono">{s.n}</span>}
            </span>
            <span className="sp-rail-label">{s.label}</span>
            <span className="sp-rail-sub">
              {state === 'done' ? 'complete' : state === 'current' ? 'in progress' : 'not started'}
            </span>
          </div>
        );
        return (
          <React.Fragment key={s.n}>
            {i > 0 ? <span className="sp-rail-line" /> : null}
            {href ? (
              <Link href={href} className="sp-rail-link">
                {node}
              </Link>
            ) : (
              node
            )}
            {gate ? (
              <>
                <span className="sp-rail-line" />
                <span className={`sp-rail-gate sp-rail-gate--${gateState(gate.after, stage)}`}>
                  <Icon
                    name={gateState(gate.after, stage) === 'passed' ? 'check' : gateState(gate.after, stage) === 'open' ? 'circle-dot' : 'lock'}
                    size={11}
                  />
                  <span className="mono">G{gate.g}</span>
                </span>
              </>
            ) : null}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// compact 7-pip version for the client table
export function StagePips({ stage }: { stage: number }) {
  return (
    <span className="sp-pips" title={`Stage ${stage} of 6`}>
      {STAGES.map((s) => (
        <span key={s.n} className={'sp-pip' + (s.n < stage ? ' is-done' : s.n === stage ? ' is-current' : '')} />
      ))}
    </span>
  );
}
