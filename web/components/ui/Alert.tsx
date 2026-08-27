import * as React from 'react';
import { Icon } from './Icon';

const ICONS = { ok: 'check', err: 'alert-triangle', info: 'info' } as const;

export function Alert({ tone = 'info', children }: { tone?: 'ok' | 'err' | 'info'; children: React.ReactNode }) {
  return (
    <div className={`sp-alert sp-alert--${tone}`} role={tone === 'err' ? 'alert' : 'status'}>
      <Icon name={ICONS[tone]} size={15} />
      <div>{children}</div>
    </div>
  );
}
