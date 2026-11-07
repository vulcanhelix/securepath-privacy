'use client';
import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Card } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { Badge } from '@/components/ui/Badge';
import { Alert } from '@/components/ui/Alert';
import { Checkbox, Field, Input, Select } from '@/components/ui/forms';

// ---------------------------------------------------------------------------
// W2-02 — onboarding wizard (spec §7.3 screen 11, FR-ONB-01).
// Multi-step COLLECTOR, server-driven: every write goes through
// /api/clients/onboard → the system RPCs (create_client_org /
// appoint_designation / create_invite / create_programme). This component
// re-implements NO validation — the RPCs are the arbiters; their errors are
// surfaced verbatim on the review step.
// ---------------------------------------------------------------------------

export interface WizardData {
  callerId: string;
  practiceName: string | null;
  homeRegion: string | null;
  practiceCountry: string | null;
  regionsAvailable: boolean;
  jurisdictions: { code: string; timezone: string | null; regulator_name: string | null; default_data_region: string | null }[];
  regions: { code: string; label: string; deployment_region: string }[];
  templates: {
    id: string; framework: string; edition: string | null;
    jurisdiction: string | null; name: string;
    versions: { id: string; number: number; release_notes: string | null }[];
  }[];
  people: { id: string; name: string; email: string }[];
}

interface StepResult { key: string; label: string; status: 'ok' | 'error' | 'skipped'; detail?: string }

const DESIGNATIONS: { role: string; label: string }[] = [
  { role: 'information_officer', label: 'Information Officer' },
  { role: 'deputy_information_officer', label: 'Deputy Information Officer' },
  { role: 'dpo', label: 'Data Protection Officer' },
  { role: 'named_alternate', label: 'Named alternate' },
];

const STEP_TITLES = [
  'Client details', 'Jurisdiction & data region', 'Statutory designations',
  'Programme', 'Client users', 'Review & create',
];

function nextMonday(): string {
  const d = new Date();
  d.setDate(d.getDate() + ((8 - d.getDay()) % 7 || 7));
  return d.toISOString().slice(0, 10);
}
const isMonday = (iso: string) => !!iso && new Date(`${iso}T00:00:00`).getDay() === 1;

export function Wizard({ data }: { data: WizardData }) {
  const router = useRouter();
  const [step, setStep] = React.useState(0);
  const [busy, setBusy] = React.useState(false);
  const [fatal, setFatal] = React.useState('');
  const [results, setResults] = React.useState<StepResult[] | null>(null);
  const [created, setCreated] = React.useState<{ client_id: string; programme_id: string | null } | null>(null);

  const [client, setClient] = React.useState({
    name: '', legal_name: '', trading_name: '', registration_number: '',
    sector: '', headcount_in_scope: '', org_scale: 'sme',
    contact_name: '', contact_email: '',
  });
  const [sites, setSites] = React.useState<{ name: string; address: string }[]>([]);
  const [jurisdiction, setJurisdiction] = React.useState(
    (data.practiceCountry && data.jurisdictions.some((j) => j.code === data.practiceCountry)
      ? data.practiceCountry : data.jurisdictions[0]?.code) ?? '');
  const [region, setRegion] = React.useState(
    data.homeRegion
      ?? data.jurisdictions.find((j) => j.code === jurisdiction)?.default_data_region
      ?? data.regions[0]?.code ?? '');
  const [desig, setDesig] = React.useState<Record<string, { person: string; date: string; ref: string }>>(
    Object.fromEntries(DESIGNATIONS.map((d) => [d.role, { person: '', date: '', ref: '' }])));
  const [makeProgramme, setMakeProgramme] = React.useState(true);
  const [versionId, setVersionId] = React.useState('');
  const [progName, setProgName] = React.useState('');
  const [progNameTouched, setProgNameTouched] = React.useState(false);
  const [startDate, setStartDate] = React.useState(nextMonday());
  const [invites, setInvites] = React.useState<{ email: string; role: string }[]>([]);

  // FR-ONB-03 — templates filtered by the client's jurisdiction; any-
  // jurisdiction templates (ISO) always offered. The RPC re-checks — this
  // filter only narrows what the picker shows.
  const offered = data.templates.filter(
    (t) => t.jurisdiction === null || t.jurisdiction === jurisdiction);
  const flatVersions = offered.flatMap((t) =>
    t.versions.map((v) => ({ id: v.id, number: v.number, tpl: t })));
  const chosenVersion = flatVersions.find((v) => v.id === versionId) ?? null;

  React.useEffect(() => {
    if (!flatVersions.some((v) => v.id === versionId)) {
      setVersionId(flatVersions.sort((a, b) => b.number - a.number)[0]?.id ?? '');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [jurisdiction]);

  const defaultProgName = chosenVersion ? `${client.name.trim() || 'Client'} — ${chosenVersion.tpl.name}` : '';
  const effectiveProgName = progNameTouched ? progName : defaultProgName;

  function canNext(): boolean {
    if (step === 0) return !!client.name.trim();
    if (step === 1) return !!jurisdiction && !!region;
    if (step === 3) return !makeProgramme || (!!versionId && !!startDate);
    return true;
  }

  async function submit() {
    setBusy(true); setFatal('');
    const payload = {
      client: {
        ...client,
        headcount_in_scope: client.headcount_in_scope === '' ? null : Number(client.headcount_in_scope),
        sites: sites.filter((s) => s.name.trim() || s.address.trim()),
        jurisdiction, data_region: region,
      },
      designations: DESIGNATIONS
        .filter((d) => desig[d.role].person)
        .map((d) => ({
          role: d.role, person: desig[d.role].person,
          date_designated: desig[d.role].date || null,
          registration_ref: desig[d.role].ref || null,
        })),
      invites: invites.filter((i) => i.email.trim()),
      programme: makeProgramme && versionId
        ? { template_version_id: versionId, name: effectiveProgName.trim(), start_date: startDate }
        : null,
    };
    const r = await fetch('/api/clients/onboard', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const body = await r.json().catch(() => ({}));
    setBusy(false);
    setResults((body.steps as StepResult[]) ?? null);
    if (!r.ok) { setFatal(body.error ?? 'creation failed'); return; }
    setCreated({ client_id: body.client_id, programme_id: body.programme_id ?? null });
    router.refresh();
  }

  const regionLabel = (code: string) =>
    data.regions.find((r) => r.code === code)?.label ?? code;

  return (
    <div style={{ maxWidth: 'var(--form-max)', display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* step rail */}
      <ol style={{ display: 'flex', gap: 8, flexWrap: 'wrap', listStyle: 'none', margin: 0, padding: 0 }}>
        {STEP_TITLES.map((t, i) => (
          <li key={t}>
            <Badge tone={i === step ? 'accent' : i < step ? 'pass' : 'neutral'}>
              {i + 1}. {t}
            </Badge>
          </li>
        ))}
      </ol>

      {/* ---- step 0: client details ---- */}
      {step === 0 && (
        <Card title="Client details" pad={20}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '0 16px' }}>
            <Field label="Client name" required>
              <Input required value={client.name} autoFocus
                onChange={(e) => setClient({ ...client, name: e.target.value })} />
            </Field>
            <Field label="Organisation scale" required
              hint="Advisor judgement — drives which assessment questions apply.">
              <Select value={client.org_scale}
                onChange={(e) => setClient({ ...client, org_scale: e.target.value })}>
                <option value="sme">SME (≤10 users)</option>
                <option value="large">Large corporation</option>
              </Select>
            </Field>
            <Field label="Legal name">
              <Input value={client.legal_name}
                onChange={(e) => setClient({ ...client, legal_name: e.target.value })} />
            </Field>
            <Field label="Trading name">
              <Input value={client.trading_name}
                onChange={(e) => setClient({ ...client, trading_name: e.target.value })} />
            </Field>
            <Field label="Registration number">
              <Input value={client.registration_number}
                onChange={(e) => setClient({ ...client, registration_number: e.target.value })} />
            </Field>
            <Field label="Sector">
              <Input value={client.sector} placeholder="e.g. Financial services"
                onChange={(e) => setClient({ ...client, sector: e.target.value })} />
            </Field>
            <Field label="Headcount in scope">
              <Input type="number" min={0} value={client.headcount_in_scope}
                onChange={(e) => setClient({ ...client, headcount_in_scope: e.target.value })} />
            </Field>
            <Field label="Primary contact name">
              <Input value={client.contact_name}
                onChange={(e) => setClient({ ...client, contact_name: e.target.value })} />
            </Field>
            <Field label="Primary contact email">
              <Input type="email" value={client.contact_email}
                onChange={(e) => setClient({ ...client, contact_email: e.target.value })} />
            </Field>
          </div>
          <Field label="Sites" hint="One per line: name — address">
            <textarea className="sp-textarea" style={{ minHeight: 68, resize: 'vertical' }}
              placeholder={'Head Office — 1 Main Rd, Joburg\nBranch — 2 Sample Rd, Cape Town'}
              value={sites.map((s) => `${s.name}${s.address ? ` — ${s.address}` : ''}`).join('\n')}
              onChange={(e) => setSites(
                e.target.value.split('\n')
                  .filter((l) => l.trim())
                  .map((l) => {
                    const [name, ...rest] = l.split('—');
                    return { name: name.trim(), address: rest.join('—').trim() };
                  }))} />
          </Field>
        </Card>
      )}

      {/* ---- step 1: jurisdiction & data region ---- */}
      {step === 1 && (
        <Card title="Jurisdiction & data region" pad={20}>
          <Field label="Jurisdiction" required
            hint="Sets the legal pack: role labels, regulator, deadlines — and which framework templates are offered next (FR-ONB-03).">
            <Select required value={jurisdiction}
              onChange={(e) => {
                const code = e.target.value;
                setJurisdiction(code);
                const jur = data.jurisdictions.find((j) => j.code === code);
                setRegion((r) => (data.regions.some((x) => x.code === r) ? r : '')
                  || data.homeRegion || jur?.default_data_region || data.regions[0]?.code || '');
              }}>
              {data.jurisdictions.map((j) => (
                <option key={j.code} value={j.code}>{j.code}</option>
              ))}
            </Select>
          </Field>
          <Field label="Data region" required
            hint={`Residency for this client's data — defaults to ${data.practiceName ?? 'the partner'}'s home region (${data.homeRegion ?? 'unset'}). One deploy per region; a wrong region is corrected by re-creating the client.`}>
            <Select required value={region} onChange={(e) => setRegion(e.target.value)}>
              <option value="" disabled>Choose…</option>
              {data.regions.map((r) => (
                <option key={r.code} value={r.code}>
                  {r.label} ({r.code} · {r.deployment_region})
                </option>
              ))}
            </Select>
          </Field>
          {data.jurisdictions.find((j) => j.code === jurisdiction)?.timezone ? (
            <p className="muted" style={{ fontSize: 'var(--fs-sm)', margin: 0 }}>
              Client timezone defaults from the pack:{' '}
              <span className="mono">{data.jurisdictions.find((j) => j.code === jurisdiction)?.timezone}</span>
            </p>
          ) : null}
        </Card>
      )}

      {/* ---- step 2: statutory designations ---- */}
      {step === 2 && (
        <Card title="Statutory designations" pad={20}>
          <p className="muted" style={{ marginTop: 0, fontSize: 'var(--fs-sm)' }}>
            Optional. Who may hold each designation is the {jurisdiction || 'client'} jurisdiction
            pack&apos;s rule and <code>appoint_designation</code> enforces it — a holder who is not
            eligible is reported on the review step, not silently dropped. Designations can also be
            recorded later on the client&apos;s Designations register (e.g. once invited client users
            have accepted and hold client roles).
          </p>
          {data.people.length === 0 ? (
            <p className="muted" style={{ fontSize: 'var(--fs-sm)' }}>
              No eligible people visible yet — invite client users below, then appoint designations
              once they have accepted.
            </p>
          ) : null}
          {DESIGNATIONS.map((d) => (
            <div key={d.role} style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr', gap: '0 12px', alignItems: 'end' }}>
              <Field label={d.label}>
                <Select value={desig[d.role].person}
                  onChange={(e) => setDesig({ ...desig, [d.role]: { ...desig[d.role], person: e.target.value } })}>
                  <option value="">— not appointed now —</option>
                  {data.people.map((p) => (
                    <option key={p.id} value={p.id}>{p.name} ({p.email})</option>
                  ))}
                </Select>
              </Field>
              <Field label="Date designated">
                <Input type="date" max={new Date().toISOString().slice(0, 10)}
                  value={desig[d.role].date} disabled={!desig[d.role].person}
                  onChange={(e) => setDesig({ ...desig, [d.role]: { ...desig[d.role], date: e.target.value } })} />
              </Field>
              <Field label="Registration ref">
                <Input value={desig[d.role].ref} disabled={!desig[d.role].person}
                  onChange={(e) => setDesig({ ...desig, [d.role]: { ...desig[d.role], ref: e.target.value } })} />
              </Field>
            </div>
          ))}
        </Card>
      )}

      {/* ---- step 3: programme ---- */}
      {step === 3 && (
        <Card title="Framework template & programme start" pad={20}>
          <div style={{ marginBottom: 12 }}>
            <Checkbox
              label="Create a programme from a published framework template"
              checked={makeProgramme} onChange={(e) => setMakeProgramme(e.target.checked)} />
          </div>
          {makeProgramme ? (
            flatVersions.length ? (
              <>
                <Field label="Framework template" required
                  hint={`Published versions filtered by jurisdiction ${jurisdiction} — templates for any jurisdiction are always offered (FR-ONB-03).`}>
                  <Select required value={versionId} onChange={(e) => setVersionId(e.target.value)}>
                    {flatVersions.map((v) => (
                      <option key={v.id} value={v.id}>
                        {v.tpl.name} — v{v.number}{v.tpl.jurisdiction ? ` (${v.tpl.jurisdiction})` : ' (any jurisdiction)'}
                      </option>
                    ))}
                  </Select>
                </Field>
                <Field label="Programme name" required>
                  <Input required value={effectiveProgName}
                    onChange={(e) => { setProgName(e.target.value); setProgNameTouched(true); }} />
                </Field>
                <Field label="Programme start date" required
                  hint="Programmes start on a Monday (§9.1) — the RPC rejects any other day.">
                  <Input type="date" required value={startDate}
                    onChange={(e) => setStartDate(e.target.value)} />
                </Field>
                {startDate && !isMonday(startDate) ? (
                  <Alert tone="err">Start date must be a Monday.</Alert>
                ) : null}
                <Field label="Source of findings">
                  <Select value="template" disabled>
                    <option value="template">Template defaults — the register starts from the template&apos;s findings map</option>
                  </Select>
                </Field>
                <p className="muted" style={{ fontSize: 'var(--fs-xs)', margin: '0 0 8px' }}>
                  Assessment import and blank-start are post-creation paths: findings import needs an
                  assessment session for this client (none exists yet — import afterwards from the
                  register); a blank register is not offered because create_programme instantiates
                  the template&apos;s findings map.
                </p>
              </>
            ) : (
              <Alert tone="err">
                No published template versions are offered for jurisdiction {jurisdiction || '—'}.
                Published any-jurisdiction templates always appear here (FR-ONB-03); ask SecurePath
                to publish one for this jurisdiction, or pick a different jurisdiction.
              </Alert>
            )
          ) : (
            <p className="muted" style={{ fontSize: 'var(--fs-sm)', margin: 0 }}>
              The client shell is created without a programme — create one later from the client workspace.
            </p>
          )}
        </Card>
      )}

      {/* ---- step 4: client users ---- */}
      {step === 4 && (
        <Card title="Client users & roles" pad={20}>
          <p className="muted" style={{ marginTop: 0, fontSize: 'var(--fs-sm)' }}>
            Optional. Each invitee gets a branded invitation and sets up MFA on first sign-in
            (FR-ONB-04). Client-side roles only — partner team seats are managed under Team.
          </p>
          {invites.map((inv, i) => (
            <div key={i} style={{ display: 'grid', gridTemplateColumns: '2fr 1fr auto', gap: '0 12px', alignItems: 'end' }}>
              <Field label={i === 0 ? 'Email' : ''}>
                <Input type="email" value={inv.email} placeholder="user@client.example"
                  onChange={(e) => setInvites(invites.map((x, j) => j === i ? { ...x, email: e.target.value } : x))} />
              </Field>
              <Field label={i === 0 ? 'Role' : ''}>
                <Select value={inv.role}
                  onChange={(e) => setInvites(invites.map((x, j) => j === i ? { ...x, role: e.target.value } : x))}>
                  <option value="client_admin">Client admin</option>
                  <option value="client_contributor">Client contributor</option>
                </Select>
              </Field>
              <Button size="sm" variant="ghost" type="button"
                onClick={() => setInvites(invites.filter((_, j) => j !== i))}>Remove</Button>
            </div>
          ))}
          <div style={{ display: 'flex', gap: 8 }}>
            <Button size="sm" variant="outline" icon="user-plus" type="button"
              onClick={() => setInvites([...invites, { email: '', role: 'client_admin' }])}>
              Add invite
            </Button>
            {client.contact_email && !invites.some((i) => i.email === client.contact_email) ? (
              <Button size="sm" variant="outline" type="button"
                onClick={() => setInvites([...invites, { email: client.contact_email, role: 'client_admin' }])}>
                Invite {client.contact_email} as client admin
              </Button>
            ) : null}
          </div>
        </Card>
      )}

      {/* ---- step 5: review & create ---- */}
      {step === 5 && (
        <Card title="Review & create" pad={20}>
          {created ? (
            <>
              <Alert tone={results?.some((s) => s.status === 'error') ? 'err' : 'ok'}>
                Client <strong>{client.name}</strong> created
                {created.programme_id ? ' with its programme' : ''}.
                {results?.some((s) => s.status === 'error')
                  ? ' Some optional steps failed — details below; nothing was silently skipped.'
                  : ''}
              </Alert>
              <div style={{ display: 'flex', gap: 8, margin: '12px 0' }}>
                <Button icon="arrow-right" onClick={() => router.push(`/clients/${created.client_id}`)}>
                  Open client
                </Button>
                {created.programme_id ? (
                  <Button variant="outline" onClick={() => router.push(`/programmes/${created.programme_id}`)}>
                    Open programme
                  </Button>
                ) : null}
                <Button variant="ghost" onClick={() => router.push('/programmes')}>Console</Button>
              </div>
            </>
          ) : (
            <>
              <table className="sp-table">
                <tbody>
                  <tr><th style={{ width: 180 }}>Client</th><td>{client.name || '—'}</td></tr>
                  {client.legal_name ? <tr><th>Legal name</th><td>{client.legal_name}</td></tr> : null}
                  {client.trading_name ? <tr><th>Trading name</th><td>{client.trading_name}</td></tr> : null}
                  {client.registration_number ? <tr><th>Registration no.</th><td>{client.registration_number}</td></tr> : null}
                  {client.sector ? <tr><th>Sector</th><td>{client.sector}</td></tr> : null}
                  {client.headcount_in_scope ? <tr><th>Headcount in scope</th><td>{client.headcount_in_scope}</td></tr> : null}
                  {sites.length ? <tr><th>Sites</th><td>{sites.map((s) => `${s.name}${s.address ? ` — ${s.address}` : ''}`).join('; ')}</td></tr> : null}
                  <tr><th>Scale</th><td>{client.org_scale === 'sme' ? 'SME' : 'Large'}</td></tr>
                  <tr><th>Jurisdiction</th><td>{jurisdiction || '—'}</td></tr>
                  <tr><th>Data region</th><td>{region ? `${regionLabel(region)} (${region})` : '—'}</td></tr>
                  <tr><th>Designations</th><td>
                    {DESIGNATIONS.filter((d) => desig[d.role].person).length
                      ? DESIGNATIONS.filter((d) => desig[d.role].person)
                          .map((d) => `${d.label}: ${data.people.find((p) => p.id === desig[d.role].person)?.name ?? '?'}`)
                          .join('; ')
                      : 'none now'}
                  </td></tr>
                  <tr><th>Programme</th><td>
                    {makeProgramme && chosenVersion
                      ? `${effectiveProgName} — ${chosenVersion.tpl.name} v${chosenVersion.number}, starts ${startDate}`
                      : 'not created now'}
                  </td></tr>
                  <tr><th>Client users</th><td>
                    {invites.filter((i) => i.email.trim()).length
                      ? invites.filter((i) => i.email.trim()).map((i) => `${i.email} (${i.role})`).join('; ')
                      : 'none invited'}
                  </td></tr>
                </tbody>
              </table>
              <p className="muted" style={{ fontSize: 'var(--fs-xs)' }}>
                Creating the client instance is a <strong>billable event</strong> — it is written to
                the billing ledger in the same call.
              </p>
              {fatal ? <Alert tone="err">{fatal}</Alert> : null}
              <div>
                <Button cta icon="check" disabled={busy} onClick={submit}>
                  {busy ? 'Creating…' : 'Create client'}
                </Button>
              </div>
            </>
          )}
          {results ? (
            <div style={{ marginTop: 16 }}>
              <h3 style={{ fontSize: 'var(--fs-sm)', margin: '0 0 8px' }}>Step results</h3>
              <ul style={{ listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexDirection: 'column', gap: 6 }}>
                {results.map((s) => (
                  <li key={s.key} style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}>
                    <Badge tone={s.status === 'ok' ? 'pass' : s.status === 'error' ? 'fail' : 'neutral'}>
                      {s.status}
                    </Badge>
                    <span>{s.label}</span>
                    {s.detail ? <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{s.detail}</span> : null}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </Card>
      )}

      {/* nav buttons */}
      {!created ? (
        <div style={{ display: 'flex', gap: 8, justifyContent: 'space-between' }}>
          <Button variant="ghost" disabled={step === 0 || busy} onClick={() => setStep(step - 1)}>
            Back
          </Button>
          {step < STEP_TITLES.length - 1 ? (
            <Button cta disabled={!canNext()} onClick={() => setStep(step + 1)}>
              Continue
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
