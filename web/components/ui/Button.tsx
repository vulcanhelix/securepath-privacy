import * as React from 'react';
import { Icon } from './Icon';

type Props = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger';
  size?: 'md' | 'sm';
  icon?: string;
  /** appends the white circle with arrow-right — one per screen, the most important action */
  cta?: boolean;
};

export function Button({ variant = 'primary', size = 'md', icon, cta, children, className, ...rest }: Props) {
  return (
    <button
      className={
        `sp-btn sp-btn--${variant} sp-btn--${size}` + (cta ? ' sp-btn--cta' : '') + (className ? ' ' + className : '')
      }
      {...rest}
    >
      {icon ? <Icon name={icon} size={size === 'sm' ? 14 : 16} /> : null}
      <span>{children}</span>
      {cta ? (
        <span className="sp-btn-circle">
          <Icon name="arrow-right" size={size === 'sm' ? 14 : 18} />
        </span>
      ) : null}
    </button>
  );
}
