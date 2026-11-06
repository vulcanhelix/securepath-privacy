'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Input, Select } from '@/components/ui/forms';
import { Button } from '@/components/ui/Button';
import { PARTNER_TYPES } from '@/lib/platform';

// W2-14 — list filters → query string → platform_list_partners(p_filters).

export function PartnerFilters({ initial }: { initial: Record<string, string> }) {
  const router = useRouter();
  const [f, setF] = React.useState<Record<string, string>>(initial);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF((o) => ({ ...o, [k]: e.target.value }));

  function apply(e: React.FormEvent) {
    e.preventDefault();
    const qs = new URLSearchParams(Object.entries(f).filter(([, v]) => v.trim() !== ''));
    router.push(`/platform/partners${qs.size ? `?${qs}` : ''}`);
  }

  return (
    <form onSubmit={apply} style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12, alignItems: 'center' }}>
      <Input placeholder="Search name" value={f.q ?? ''} onChange={set('q')} style={{ width: 200 }} />
      <Select value={f.status ?? ''} onChange={set('status')} aria-label="Status">
        <option value="">Any status</option>
        <option value="active">Active</option>
        <option value="suspended">Suspended</option>
        <option value="closed">Closed</option>
      </Select>
      <Select value={f.type ?? ''} onChange={set('type')} aria-label="Type">
        <option value="">Any type</option>
        {PARTNER_TYPES.map((t) => (
          <option key={t.value} value={t.value}>{t.label}</option>
        ))}
      </Select>
      <Input placeholder="Country" value={f.country ?? ''} onChange={set('country')} style={{ width: 100 }} />
      <Button size="sm" variant="outline" type="submit" icon="filter">Filter</Button>
    </form>
  );
}
