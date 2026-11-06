'use client';
import * as React from 'react';

// W2-07 — dates render in the CLIENT's timezone/locale (hard rule). Date-only
// values (YYYY-MM-DD) carry no zone, so they are formatted as calendar dates
// (UTC midnight → no day shift); timestamps use the browser's zone. Until
// hydration the raw ISO value is shown so server and client markup match.

export function LocalDate({
  value,
  withTime = false,
  empty = '—',
}: {
  value: string | null | undefined;
  withTime?: boolean;
  empty?: React.ReactNode;
}) {
  const [text, setText] = React.useState<string | null>(null);
  React.useEffect(() => {
    if (!value) return;
    const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
    const d = new Date(dateOnly ? `${value}T00:00:00Z` : value);
    if (Number.isNaN(d.getTime())) return;
    setText(
      new Intl.DateTimeFormat(undefined, {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
        ...(withTime && !dateOnly ? { hour: '2-digit', minute: '2-digit' } : {}),
        ...(dateOnly ? { timeZone: 'UTC' } : {}),
      }).format(d)
    );
  }, [value, withTime]);
  if (!value) return <>{empty}</>;
  return <time dateTime={value}>{text ?? value.slice(0, withTime ? 16 : 10)}</time>;
}
