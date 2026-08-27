import * as React from 'react';
import { Icon } from './Icon';

export function EmptyState({ icon = 'inbox', message, action }: { icon?: string; message: React.ReactNode; action?: React.ReactNode }) {
  return (
    <div className="sp-empty">
      <span className="sp-empty-ic">
        <Icon name={icon} size={20} />
      </span>
      <p className="sp-empty-msg">{message}</p>
      {action}
    </div>
  );
}
