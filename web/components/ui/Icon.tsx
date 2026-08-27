import * as React from 'react';
import { icons } from 'lucide-react';

// lucide kebab-case name ("arrow-right") to PascalCase export ("ArrowRight")
function pascal(name: string) {
  return name.replace(/(^|-)([a-z0-9])/g, (_, __, c) => c.toUpperCase());
}

export function Icon({ name, size = 16, className }: { name: string; size?: number; className?: string }) {
  const L = icons[pascal(name) as keyof typeof icons];
  if (!L) return null;
  return (
    <span
      className={'sp-icon' + (className ? ' ' + className : '')}
      aria-hidden="true"
      style={{ display: 'inline-flex', width: size, height: size, flex: 'none' }}
    >
      <L width="100%" height="100%" strokeWidth={1.75} />
    </span>
  );
}
