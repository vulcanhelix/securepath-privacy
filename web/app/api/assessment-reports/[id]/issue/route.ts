import { createHash } from 'crypto';
import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';
import { renderReportHtml } from '@/lib/report/render';
import type { ReportOverrides, ReportPayload } from '@/lib/report/types';

// Issue an approved assessment report: render the final self-contained HTML, freeze it in
// object storage, and let the RPC create the immutable evidence document + supersede the
// predecessor. Version+id in the key — re-issues can never collide.

// SSRF guard: logo_url is practice-owner-controlled and fetched server-side, and the
// staging services bind loopback — require https and refuse loopback/private/link-local
// hosts. ponytail: hostname checks don't stop DNS rebinding; resolve-and-check the IP
// before connecting if logo hosting ever becomes untrusted-multi-tenant.
function isSafeLogoUrl(raw: string): boolean {
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== 'https:') return false;
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost')) return false;
  if (/^(127\.|10\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|0\.)/.test(h)) return false;
  if (h === '::1' || /^f[cd]/.test(h) || h.startsWith('fe80:')) return false;
  return true;
}
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const [{ data: report }, { data: practice }] = await Promise.all([
    supabase.from('assessment_reports')
      .select('client_org_id, framework_key, version, payload, overrides, approval_status')
      .eq('id', id).maybeSingle(),
    supabase.from('practices').select('name, accent_hex, logo_url').maybeSingle(),
  ]);
  if (!report) return NextResponse.json({ error: 'not found' }, { status: 404 });
  if (report.approval_status !== 'approved')
    return NextResponse.json({ error: 'only an approved report can be issued' }, { status: 409 });

  // inline the practice logo so the archived artifact is fully self-contained
  let logo: string | null = practice?.logo_url ?? null;
  if (logo && !isSafeLogoUrl(logo)) logo = null;
  if (logo) {
    const sourceLogo = logo;
    logo = null;
    try {
      const res = await fetch(sourceLogo, { signal: AbortSignal.timeout(5000), redirect: 'error' });
      const type = res.headers.get('content-type') ?? '';
      if (res.ok && type.startsWith('image/')) {
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length <= 512 * 1024) logo = `data:${type};base64,${buf.toString('base64')}`;
      }
    } catch { /* issue without a logo rather than archiving an external dependency */ }
  }

  const html = renderReportHtml(
    report.payload as ReportPayload,
    (report.overrides ?? {}) as ReportOverrides,
    { practiceName: practice?.name ?? '', accentHex: practice?.accent_hex ?? null, logo },
  );

  const bytes = new TextEncoder().encode(html);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${report.client_org_id}/assessment-report-${report.framework_key}-v${report.version}-${id}.html`;
  await putObject(key, bytes, 'text/html');

  const { data: documentId, error } = await supabase.rpc('issue_assessment_report', {
    p_report_id: id, p_storage_path: key, p_sha256: sha256, p_size: bytes.length,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ document_id: documentId });
}
