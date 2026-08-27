'use client';
import * as React from 'react';
import { Icon } from './Icon';

export function ThemeToggle() {
  const [dark, setDark] = React.useState(false);
  React.useEffect(() => {
    setDark(document.documentElement.getAttribute('data-theme') === 'dark');
  }, []);
  function toggle() {
    const next = !dark;
    setDark(next);
    document.documentElement.setAttribute('data-theme', next ? 'dark' : 'light');
    try {
      localStorage.setItem('sp-theme', next ? 'dark' : 'light');
    } catch {}
  }
  return (
    <button type="button" className="sp-btn sp-btn--ghost sp-btn--sm" onClick={toggle} aria-label="Toggle dark mode">
      <Icon name={dark ? 'sun' : 'moon'} size={14} />
      <span>{dark ? 'Light' : 'Dark'}</span>
    </button>
  );
}
