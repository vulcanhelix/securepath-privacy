import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Select } from '@/components/ui/forms';
import { Button } from '@/components/ui/Button';
import {
  RaidBoard,
  type RaidItem,
  type RaidHistory,
  type Decision,
  type Person,
} from './RaidBoard';

export const dynamic = 'force-dynamic';

// W2-11 — RAID log + decisions (spec §8.8 FR-RAI-01..03). Reads via the W1-06
// RPCs list_raid_items / list_decisions and the append-only
// raid_status_history table (RLS T2-via-raid), all under the caller's JWT.
// Filters are GET params so the list is server-filtered by the RPC itself.
// Role checks below only decide which controls render; create/update/resolve/
// record_decision re-check has_programme_role in their definer bodies.

const WRITE_ROLES = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];
const RAID_PLUS = [...WRITE_ROLES, 'executive', 'accountable_officer'];
const STATUSES = ['Open', 'In progress', 'Closed'];
const TYPES = ['risk', 'assumption', 'issue'];

export default async function RaidPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ status?: string; type?: string; owner?: string }>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();

  const status = STATUSES.includes(sp.status ?? '') ? sp.status! : null;
  const type = TYPES.includes(sp.type ?? '') ? sp.type! : null;
  const ownerParam = sp.owner === 'me' ? ctx.role.userId : sp.owner || null;
  const owner = ownerParam && /^[0-9a-f-]{36}$/i.test(ownerParam) ? ownerParam : null;

  const [itemsRes, allRes, decRes, { data: canWrite }, { data: canRaise }] = await Promise.all([
    supabase.rpc('list_raid_items', {
      p_programme_id: id,
      p_status: status,
      p_type: type,
      p_owner: owner,
    }),
    // unfiltered set for headline counts + owner options
    supabase.rpc('list_raid_items', { p_programme_id: id }),
    supabase.rpc('list_decisions', { p_programme_id: id }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: WRITE_ROLES }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: RAID_PLUS }),
  ]);

  const items = (itemsRes.data ?? []) as RaidItem[];
  const all = (allRes.data ?? []) as RaidItem[];
  const decisions = (decRes.data ?? []) as Decision[];

  let history: RaidHistory[] = [];
  if (items.length) {
    const { data } = await supabase
      .from('raid_status_history')
      .select('id, raid_item_id, old_status, new_status, changed_by, changed_at, note')
      .in('raid_item_id', items.map((i) => i.id))
      .order('changed_at', { ascending: false });
    history = (data ?? []) as RaidHistory[];
  }

  // People: users is self-or-partner_admin readable (users_self). Anyone the
  // caller cannot read renders as a short id — no directory RPC exists yet.
  const ids = new Set<string>([ctx.role.userId]);
  for (const i of all) if (i.owner) ids.add(i.owner);
  for (const h of history) if (h.changed_by) ids.add(h.changed_by);
  for (const d of decisions) if (d.decided_by) ids.add(d.decided_by);
  const { data: users } = await supabase
    .from('users')
    .select('id, email, full_name')
    .in('id', [...ids]);
  const people: Person[] = (users ?? []).map((u) => ({
    id: u.id as string,
    label: ((u.full_name as string) || (u.email as string)) + (u.id === ctx.role.userId ? ' (you)' : ''),
  }));
  if (!people.some((p) => p.id === ctx.role.userId)) people.push({ id: ctx.role.userId, label: 'You' });

  const today = new Date().toISOString().slice(0, 10);
  const openCount = all.filter((i) => i.status !== 'Closed').length;
  const overdue = all.filter((i) => i.status !== 'Closed' && i.review_by && i.review_by < today).length;
  const count = (t: string) => all.filter((i) => i.type === t && i.status !== 'Closed').length;
  const error = itemsRes.error?.message ?? decRes.error?.message ?? null;
  const filtered = status || type || owner;

  return (
    <>
      <PageHeader
        title="RAID & decisions"
        meta={`${openCount} open · ${decisions.length} decision${decisions.length === 1 ? '' : 's'} recorded`}
      />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 20 }}>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{count('risk')}</div>
          <div className="muted">Open risks</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{count('issue')}</div>
          <div className="muted">Open issues</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28 }}>{count('assumption')}</div>
          <div className="muted">Open assumptions</div>
        </Card>
        <Card pad={16} style={{ flex: '1 1 120px' }}>
          <div className="mono" style={{ fontSize: 28, color: overdue ? 'var(--fail)' : undefined }}>{overdue}</div>
          <div className="muted">Past review date</div>
        </Card>
      </div>

      {error ? <Alert tone="err">{`Could not load the RAID log: ${error}`}</Alert> : null}

      <form method="get" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center', marginBottom: 12 }}>
        <Select name="status" defaultValue={status ?? ''} aria-label="Status" style={{ width: 'auto' }}>
          <option value="">All statuses</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </Select>
        <Select name="type" defaultValue={type ?? ''} aria-label="Type" style={{ width: 'auto' }}>
          <option value="">All types</option>
          {TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
        </Select>
        <Select name="owner" defaultValue={sp.owner ?? ''} aria-label="Owner" style={{ width: 'auto' }}>
          <option value="">Any owner</option>
          <option value="me">Mine</option>
          {people
            .filter((p) => p.id !== ctx.role.userId && all.some((i) => i.owner === p.id))
            .map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
        </Select>
        <Button size="sm" variant="outline" type="submit" icon="filter">Filter</Button>
        {filtered ? (
          <a href={`/programmes/${id}/raid`} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>Clear</a>
        ) : null}
      </form>

      <RaidBoard
        programmeId={id}
        items={items}
        history={history}
        decisions={decisions}
        people={people}
        today={today}
        canWrite={canWrite === true}
        canRaise={canRaise === true}
        filtered={!!filtered}
      />
    </>
  );
}
