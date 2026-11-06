import Link from 'next/link';
import { notFound } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { programmeContext } from '@/lib/programme-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { Alert } from '@/components/ui/Alert';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { Icon } from '@/components/ui/Icon';
import { Input, Select } from '@/components/ui/forms';
import { RegisterList, type OpRecord, type Person } from './RegisterList';
import { ProvidersPanel, type Provider } from './ProvidersPanel';

export const dynamic = 'force-dynamic';

// W2-09 — client-level operational registers (spec §8.10 screen 06,
// FR-OPS-01..05) for this programme's client. Every read is a W1-04 RPC under
// the caller's JWT (list_operational_records / list_external_providers are
// scope-checked definers); due_date and the overdue flag come from the server
// (jurisdiction-pack trigger + the RPC's own `overdue` filter) — nothing here
// computes a deadline. Role checks only decide which controls render; every
// write RPC re-checks its gate in the definer body.

const REGISTER_WRITE = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin', 'accountable_officer'];
const PROVIDER_WRITE = ['partner_admin', 'partner_consultant', 'programme_lead', 'client_admin'];

// the shipped CHECK vocabulary on operational_records.type
const TABS = [
  { key: 'dsr', label: 'Data subject requests', icon: 'user-search' },
  { key: 'breach', label: 'Breaches & incidents', icon: 'siren' },
  { key: 'disclosure', label: 'Disclosures', icon: 'share-2' },
  { key: 'optout', label: 'Opt-outs & objections', icon: 'ban' },
] as const;
type RegisterType = (typeof TABS)[number]['key'];
const STATUSES = ['Open', 'In progress', 'Awaiting decision', 'Closed'];
const PAGE = 50;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type SP = {
  tab?: string;
  status?: string;
  overdue?: string;
  due_after?: string;
  due_before?: string;
  reported_after?: string;
  reported_before?: string;
  offset?: string;
};

/** UTC instant of local midnight on `day` in IANA zone `tz` (filters are
    entered as client-local calendar days; reported_at is a timestamptz). */
function zonedMidnightISO(day: string, tz: string): string {
  const [y, m, d] = day.split('-').map(Number);
  const guess = Date.UTC(y, m - 1, d);
  try {
    const parts = Object.fromEntries(
      new Intl.DateTimeFormat('en-US', {
        timeZone: tz,
        hourCycle: 'h23',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
      })
        .formatToParts(new Date(guess))
        .map((p) => [p.type, p.value])
    );
    const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
    return new Date(guess - (asUtc - guess)).toISOString();
  } catch {
    return new Date(guess).toISOString();
  }
}

function nextDay(day: string): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

export default async function RegistersPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<SP>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await serverClient();
  const ctx = await programmeContext(id, supabase);
  if (!ctx) notFound();
  const clientId = ctx.client.id;

  const tab: RegisterType | 'providers' =
    sp.tab === 'providers' ? 'providers' : (TABS.find((t) => t.key === sp.tab)?.key ?? 'dsr');

  // ---- client timezone (NFR-10): client_orgs.timezone → jurisdiction pack → UTC
  let tz = 'UTC';
  {
    const { data: co } = await supabase.from('client_orgs').select('timezone').eq('id', clientId).maybeSingle();
    let found = (co as { timezone?: string | null } | null)?.timezone ?? null;
    if (!found && ctx.client.jurisdiction) {
      const { data: jp } = await supabase
        .from('jurisdiction_packs')
        .select('timezone')
        .eq('code', ctx.client.jurisdiction)
        .maybeSingle();
      found = (jp as { timezone?: string | null } | null)?.timezone ?? null;
    }
    if (found) {
      try {
        new Intl.DateTimeFormat('en-GB', { timeZone: found });
        tz = found;
      } catch {
        /* unknown zone — stay on UTC */
      }
    }
  }

  // ---- filters → the RPC's p_filters contract (decision 7 in the migration)
  const status = STATUSES.includes(sp.status ?? '') ? sp.status! : '';
  const overdue = sp.overdue === 'true' || sp.overdue === 'false' ? sp.overdue : '';
  const dueAfter = DATE_RE.test(sp.due_after ?? '') ? sp.due_after! : '';
  const dueBefore = DATE_RE.test(sp.due_before ?? '') ? sp.due_before! : '';
  const repAfter = DATE_RE.test(sp.reported_after ?? '') ? sp.reported_after! : '';
  const repBefore = DATE_RE.test(sp.reported_before ?? '') ? sp.reported_before! : '';
  const offset = Math.max(0, parseInt(sp.offset ?? '0', 10) || 0);
  const filters: Record<string, string | number | boolean> = { limit: PAGE, offset };
  if (status) filters.status = status;
  if (overdue) filters.overdue = overdue === 'true';
  if (dueAfter) filters.due_after = dueAfter; // inclusive (>=)
  if (dueBefore) filters.due_before = nextDay(dueBefore); // RPC is exclusive (<) — UI "to" is inclusive
  if (repAfter) filters.reported_after = zonedMidnightISO(repAfter, tz);
  if (repBefore) filters.reported_before = zonedMidnightISO(nextDay(repBefore), tz);
  const filtered = !!(status || overdue || dueAfter || dueBefore || repAfter || repBefore);

  const [listRes, providersRes, { data: canWrite }, { data: canProviders }, isAo, ...overdueRes] = await Promise.all([
    tab === 'providers'
      ? Promise.resolve({ data: [] as OpRecord[], error: null })
      : supabase.rpc('list_operational_records', { p_client_org: clientId, p_register_type: tab, p_filters: filters }),
    supabase.rpc('list_external_providers', { p_client_org: clientId }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: REGISTER_WRITE }),
    supabase.rpc('has_programme_role', { p_programme: id, p_roles: PROVIDER_WRITE }),
    ctx.role.isAoOrAlternate(clientId),
    // server-side overdue set per register (badge counts + row flags)
    ...TABS.map((t) =>
      supabase.rpc('list_operational_records', {
        p_client_org: clientId,
        p_register_type: t.key,
        p_filters: { overdue: true, limit: 200 },
      })
    ),
  ]);

  const records = (listRes.data ?? []) as OpRecord[];
  const providers = (providersRes.data ?? []) as Provider[];
  const overdueByType = new Map<string, string[]>(
    TABS.map((t, i) => [t.key, ((overdueRes[i]?.data ?? []) as OpRecord[]).map((r) => r.id)])
  );
  const overdueIds = tab === 'providers' ? [] : (overdueByType.get(tab) ?? []);

  // People: users is self-or-partner_admin readable; others render as short ids.
  const ids = new Set<string>([ctx.role.userId]);
  for (const r of records) {
    if (r.reported_by) ids.add(r.reported_by);
    const hist = (r.regulator_notification as { history?: { decided_by?: string }[] } | null)?.history ?? [];
    for (const h of hist) if (h.decided_by) ids.add(h.decided_by);
  }
  const { data: users } = await supabase.from('users').select('id, email, full_name').in('id', [...ids]);
  const people: Person[] = (users ?? []).map((u) => ({
    id: u.id as string,
    label: ((u.full_name as string) || (u.email as string)) + (u.id === ctx.role.userId ? ' (you)' : ''),
  }));

  const listError = (listRes.error as { message: string } | null)?.message ?? null;
  const base = `/programmes/${id}/registers`;
  const q = (extra: Record<string, string | number | undefined>) => {
    const u = new URLSearchParams();
    const all: Record<string, string | number | undefined> = {
      tab,
      status: status || undefined,
      overdue: overdue || undefined,
      due_after: dueAfter || undefined,
      due_before: dueBefore || undefined,
      reported_after: repAfter || undefined,
      reported_before: repBefore || undefined,
      ...extra,
    };
    for (const [k, v] of Object.entries(all)) if (v !== undefined && v !== '') u.set(k, String(v));
    return `${base}?${u.toString()}`;
  };

  return (
    <>
      <PageHeader
        title="Operational registers"
        meta={`${ctx.client.name} · client-level registers, shared across programmes · times in ${tz}`}
      />

      <nav className="sp-tabs" aria-label="Register type" style={{ marginBottom: 16 }}>
        {TABS.map((t) => {
          const n = overdueByType.get(t.key)?.length ?? 0;
          return (
            <Link key={t.key} href={`${base}?tab=${t.key}`} className={'sp-tab' + (tab === t.key ? ' is-active' : '')}>
              <Icon name={t.icon} size={14} />
              {t.label}
              {n ? <Badge tone="fail">{n >= 200 ? '200+' : n} overdue</Badge> : null}
            </Link>
          );
        })}
        <Link href={`${base}?tab=providers`} className={'sp-tab' + (tab === 'providers' ? ' is-active' : '')}>
          <Icon name="building-2" size={14} />
          External providers
          <span className="muted">{providers.length || ''}</span>
        </Link>
      </nav>

      {tab === 'providers' ? (
        <>
          {providersRes.error ? (
            <Alert tone="err">{`Could not load external providers: ${providersRes.error.message}`}</Alert>
          ) : null}
          <ProvidersPanel clientId={clientId} providers={providers} canWrite={canProviders === true} />
        </>
      ) : (
        <>
          {listError ? <Alert tone="err">{`Could not load the register: ${listError}`}</Alert> : null}

          <form method="get" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'end', marginBottom: 12 }}>
            <input type="hidden" name="tab" value={tab} />
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Status</span>
              <Select name="status" defaultValue={status} style={{ width: 'auto' }}>
                <option value="">All statuses</option>
                {STATUSES.map((s) => (
                  <option key={s} value={s}>{s}</option>
                ))}
              </Select>
            </label>
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Overdue</span>
              <Select name="overdue" defaultValue={overdue} style={{ width: 'auto' }}>
                <option value="">Any</option>
                <option value="true">Overdue only</option>
                <option value="false">Not overdue</option>
              </Select>
            </label>
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Due from</span>
              <Input type="date" name="due_after" defaultValue={dueAfter} />
            </label>
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Due to</span>
              <Input type="date" name="due_before" defaultValue={dueBefore} />
            </label>
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Reported from</span>
              <Input type="date" name="reported_after" defaultValue={repAfter} />
            </label>
            <label className="sp-field" style={{ margin: 0 }}>
              <span className="sp-field-label">Reported to</span>
              <Input type="date" name="reported_before" defaultValue={repBefore} />
            </label>
            <Button size="sm" variant="outline" type="submit" icon="filter">Filter</Button>
            {filtered ? (
              <a href={`${base}?tab=${tab}`} className="muted" style={{ fontSize: 'var(--fs-sm)' }}>Clear</a>
            ) : null}
          </form>

          <RegisterList
            clientId={clientId}
            clientName={ctx.client.name}
            type={tab}
            records={records}
            overdueIds={overdueIds}
            people={people}
            tz={tz}
            canWrite={canWrite === true}
            isAo={isAo}
            filtered={filtered}
          />

          {offset > 0 || records.length === PAGE ? (
            <Card pad={12} style={{ marginTop: 12 }}>
              <div style={{ display: 'flex', gap: 12, justifyContent: 'space-between' }}>
                {offset > 0 ? (
                  <Link href={q({ offset: Math.max(0, offset - PAGE) || undefined })}>← Newer</Link>
                ) : <span />}
                <span className="muted">
                  {records.length ? `Records ${offset + 1}–${offset + records.length}` : 'No more records'}
                </span>
                {records.length === PAGE ? <Link href={q({ offset: offset + PAGE })}>Older →</Link> : <span />}
              </div>
            </Card>
          ) : null}
        </>
      )}
    </>
  );
}
