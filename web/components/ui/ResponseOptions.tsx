'use client';
import * as React from 'react';
import { Icon } from './Icon';

export const RESPONSE_OPTIONS = [
  { value: 'fully_compliant', label: 'Yes – Fully Compliant', tone: 'pass', icon: 'check' },
  { value: 'partial', label: 'Yes – Partially Compliant', tone: 'warn', icon: 'minus' },
  { value: 'non_compliant', label: 'No – Non-Compliant', tone: 'fail', icon: 'x' },
  { value: 'na', label: 'N/A – Not Applicable', tone: 'neutral', icon: 'circle-slash' },
] as const;

export function ResponseOptions({ value, onChange }: { value?: string | null; onChange?: (v: string) => void }) {
  return (
    <div className="sp-resp" role="radiogroup">
      {RESPONSE_OPTIONS.map((o) => {
        const sel = value === o.value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={sel}
            className={`sp-resp-opt sp-resp--${o.tone}` + (sel ? ' is-sel' : '')}
            onClick={() => onChange?.(o.value)}
          >
            <span className="sp-resp-ic">
              <Icon name={o.icon} size={13} />
            </span>
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
