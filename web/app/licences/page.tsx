import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { getRoleContext } from '@/lib/role-context';
import { PageHeader } from '@/components/ui/PageHeader';
import { Card } from '@/components/ui/Card';
import { DataTable } from '@/components/ui/DataTable';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { EmptyState } from '@/components/ui/EmptyState';
import { dateLabel } from '@/lib/platform';
import {
  SEAT_CAP, pct, usageBadgeTone, licenceWarningText,
  type OwnUsageRow, type LicenceUsageRow, type OwnLicenceRow, type LicenceWarningEvent,
} from '@/lib/licence';

export const dynamic = 'force-dynamic';

// ---------------------------------------------------------------------------
// W2-17 — FR-LIC-01: "partner admins see their licence, limits and current
// usage". Full detail over the W1-07 RPCs: usage_report (own partner) for the
// numbers, the licences row (admin-read policy) for term + attribution, the
// licence_warning notification events for the §10/W1-07 warning surface, and
// the 5-seat counter for completeness.
// partner_admin only for the licence columns (spec §4.1: licence and usage
// reports = admin "Own"); other partner roles see the §9.8 counters they may
// read via partner_licence_usage.
// ---------------------------------------------------------------------------

const SEAT_ROLES = ['partner_consultant', 'read_only'];
const SEAT_INVITE_ROLES = ['practice_consultant', 'read_only'];

function UsageLine({ label, used, limit, over }: {
  label: string; used: number; limit: number | null; over?: boolean;
}) {
  const tone = usageBadgeTone(used, limit, over);
  const p = pct(used, limit);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      <span style={{ width: 110 }}>{label}</span>
      <span className="mono" style={{ fontWeight: 600, color: tone === 'pass' ? undefined : `var(--${tone})` }}>
        {used} / {limit == null ? '∞' : limit}
      </span>
      {p != null ? <Badge tone={tone}>{p}%</Badge> : <Badge tone="neutral">uncapped</Badge>}
      {tone === 'fail' ? <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>at/over the cap — SecurePath has been notified</span>
        : tone === 'warn' ? <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>approaching the cap</span>
        : null}
    </div>
  );
}

export default async function Licences() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');
  const role = await getRoleContext(supabase);
  if (!role) redirect('/login');

  const isAdmin = role.hasRole('partner', 'partner_admin');
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: clients }, { data: seats }, { data: invites }, { data: licenceRows }, { data: warnings }] =
    await Promise.all([
      supabase.from('client_orgs').select('id, practice_id').limit(1),
      supabase
        .from('role_assignments').select('user_id, role, scope_type, level')
        .in('level', ['partner']).eq('scope_type', 'partner')
        .or(`end_date.is.null,end_date.gt.${today}`),
      supabase
        .from('invites').select('role').is('accepted_at', null)
        .gt('expires_at', new Date().toISOString()),
      supabase
        .from('licences')
        .select('id, plan, status, client_limit, programme_limit, starts_on, ends_on, attribution_display')
        .order('starts_on', { ascending: false }),
      supabase
        .from('notification_events').select('created_at, payload')
        .eq('kind', 'licence_warning')
        .order('created_at', { ascending: false }).limit(10),
    ]);

  const partnerId = role.partnerIds[0] ?? clients?.[0]?.practice_id ?? null;

  let usage: OwnUsageRow | null = null;
  let lu: LicenceUsageRow | null = null;
  if (partnerId) {
    if (isAdmin) {
      const { data } = await supabase.rpc('usage_report', { p_partner: partnerId });
      usage = (data?.[0] ?? null) as OwnUsageRow | null;
    }
    if (!usage) {
      const { data } = await supabase.rpc('partner_licence_usage', { p_partner: partnerId });
      lu = (data?.[0] ?? null) as LicenceUsageRow | null;
    }
  }

  const licence = ((licenceRows ?? []) as OwnLicenceRow[]).find((l) => l.status === 'active')
    ?? ((licenceRows ?? []) as OwnLicenceRow[])[0] ?? null;
  const warns = (warnings ?? []) as LicenceWarningEvent[];
  const seatsUsed =
    new Set(((seats ?? []) as { user_id: string; role: string; scope_type: string }[])
      .filter((a) => a.scope_type === 'partner' && SEAT_ROLES.includes(a.role))
      .map((a) => a.user_id)).size
    + ((invites ?? []) as { role: string }[]).filter((i) => SEAT_INVITE_ROLES.includes(i.role)).length;

  const cUsed = usage?.clients_used ?? lu?.clients_used ?? 0;
  const cLimit = usage?.client_limit ?? lu?.client_limit ?? licence?.client_limit ?? null;
  const pUsed = usage?.programmes_used ?? lu?.programmes_used ?? 0;
  const pLimit = usage?.programme_limit ?? lu?.programme_limit ?? licence?.programme_limit ?? null;

  const daysToEnd = licence?.ends_on
    ? Math.ceil((new Date(licence.ends_on).getTime() - Date.now()) / 86_400_000)
    : null;

  return (
    <>
      <PageHeader
        title="Licence & usage"
        meta="Your SecurePath licence, its limits and what you're currently using."
        back="Team" backHref="/team"
      />

      {!partnerId || (!usage && !lu && !licence) ? (
        <>
          <Alert tone="info">
            {isAdmin
              ? 'No licence is visible for this partner — SecurePath issues licences from the platform console.'
              : 'Licence detail is limited to partner admins (spec §4.1).'}
          </Alert>
          {!isAdmin ? (
            <Card pad={0} style={{ marginTop: 24 }}>
              <EmptyState icon="badge-check" message="Ask your partner admin for licence detail." />
            </Card>
          ) : null}
        </>
      ) : (
        <>
          {/* ---- the licence itself (admin-readable fields only; a caller
                  with just the §9.8 counters skips this card) ---- */}
          {usage || licence ? (
            <Card title="Licence">
              <div style={{ display: 'grid', gap: 8 }}>
                <div>
                  <Badge tone={(usage?.licence_status ?? licence?.status) === 'active' ? 'pass' : 'warn'}>
                    {usage?.licence_status ?? licence?.status ?? 'none'}
                  </Badge>{' '}
                  <strong style={{ fontSize: 'var(--fs-lg)' }}>{usage?.plan ?? licence?.plan ?? 'No active licence'}</strong>
                </div>
                <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
                  Term: {dateLabel(licence?.starts_on)} → {licence?.ends_on ? dateLabel(licence.ends_on) : 'open-ended'}
                  {daysToEnd != null ? ` · ${daysToEnd} day${daysToEnd === 1 ? '' : 's'} left` : ''}
                </div>
                {licence ? (
                  <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                    SecurePath attribution line: {licence.attribution_display ? 'shown (per licence)' : 'hidden'}
                  </div>
                ) : null}
                {daysToEnd != null && daysToEnd <= 30 ? (
                  <Alert tone={daysToEnd <= 0 ? 'err' : 'info'}>
                    {daysToEnd <= 0 ? 'This licence term has ended.' : `This licence term ends in ${daysToEnd} days — contact SecurePath to renew.`}
                  </Alert>
                ) : null}
              </div>
            </Card>
          ) : null}

          {/* ---- usage vs caps ---- */}
          <Card title="Current usage" style={{ marginTop: 24 }}>
            <div style={{ display: 'grid', gap: 12 }}>
              <UsageLine label="Clients" used={cUsed} limit={cLimit} over={lu?.over_client_limit} />
              <UsageLine label="Programmes" used={pUsed} limit={pLimit} over={lu?.over_programme_limit} />
              {/* seats are only countable by the admin (RLS sees the whole
                  partner-scope roster); other roles would under-count */}
              {isAdmin ? <UsageLine label="Team seats" used={seatsUsed} limit={SEAT_CAP} /> : null}
              {usage ? (
                <div className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
                  Active users across the partner and its clients: <strong>{usage.active_users}</strong>
                </div>
              ) : null}
            </div>
          </Card>

          {/* ---- by-framework split (FR-LIC-02 column) ---- */}
          {usage && Object.keys(usage.programmes_by_framework ?? {}).length ? (
            <Card title="Programmes by framework" pad={0} style={{ marginTop: 24 }}>
              <DataTable
                columns={[{ label: 'Framework' }, { label: 'Programmes', align: 'right' }]}
                rows={Object.entries(usage.programmes_by_framework).map(([fw, n]) => [
                  fw, <span key="n" className="mono">{n}</span>,
                ])}
              />
            </Card>
          ) : null}

          {/* ---- W1-07 warning surface ---- */}
          <Card title="Licence warnings" pad={warns.length ? 0 : 28} style={{ marginTop: 24 }}>
            {warns.length ? (
              <DataTable
                columns={[{ label: 'Warning' }, { label: 'When', align: 'right' }]}
                rows={warns.map((w) => [
                  <span key="w"><Badge tone="warn" dot>{licenceWarningText(w)}</Badge></span>,
                  <span key="t" className="mono" style={{ fontSize: 'var(--fs-xs)', color: 'var(--muted)' }}>
                    {new Date(w.created_at).toLocaleString()}
                  </span>,
                ])}
              />
            ) : (
              <p className="muted" style={{ margin: 0 }}>
                None. A warning is raised (and SecurePath notified) when usage reaches 80% of a cap or the term is within 30 days of ending.
              </p>
            )}
          </Card>
        </>
      )}
    </>
  );
}
