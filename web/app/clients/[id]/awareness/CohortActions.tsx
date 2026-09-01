'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/forms';

export default function CohortActions({ clientOrgId, framework, planned }:
  { clientOrgId: string; framework: string; planned: number | null }) {
  const router = useRouter();
  const [dept, setDept] = useState('');
  const [plan, setPlan] = useState(planned != null ? String(planned) : '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  async function createCohort() {
    if (!dept.trim()) { setErr('department required'); return; }
    setBusy(true); setErr('');
    const { error } = await browserClient().rpc('create_awareness_cohort', {
      p_client_org_id: clientOrgId, p_department: dept.trim(), p_framework: framework,
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setDept(''); router.refresh();
  }

  async function savePlanned() {
    const n = parseInt(plan, 10);
    if (!n) return;
    setBusy(true); setErr('');
    const { error } = await browserClient().rpc('set_awareness_departments_planned', {
      p_client_org_id: clientOrgId, p_count: n,
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    router.refresh();
  }

  return (
    <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
      <Input placeholder="departments planned" type="number" min={1} value={plan}
        onChange={e => setPlan(e.target.value)} onBlur={savePlanned} style={{ width: 150 }} />
      <Input placeholder="Department (e.g. Finance)" value={dept}
        onChange={e => setDept(e.target.value)} style={{ width: 200 }} />
      <Button size="sm" disabled={busy} onClick={createCohort}>New cohort</Button>
      {err && <span style={{ color: 'var(--fail)', fontSize: 'var(--fs-xs)' }}>{err}</span>}
    </span>
  );
}
