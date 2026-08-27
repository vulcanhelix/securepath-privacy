import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { renderReportHtml } from '@/lib/report/render';
import type { ReportOverrides, ReportPayload } from '@/lib/report/types';

// Live preview of a report (draft or issued) rendered from its stored payload+overrides.
// RLS is the access check: clients can only load issued/superseded versions.
// Browser print on this page is the PDF path.
export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const reportId = req.nextUrl.searchParams.get('report');
  if (!reportId) return NextResponse.json({ error: 'report param required' }, { status: 400 });

  const [{ data: report }, { data: practice }] = await Promise.all([
    supabase.from('assessment_reports').select('client_org_id, payload, overrides, compiled_at')
      .eq('id', reportId).eq('client_org_id', id).maybeSingle(),
    supabase.from('practices').select('name, accent_hex, logo_url').maybeSingle(),
  ]);
  if (!report) return NextResponse.json({ error: 'not found' }, { status: 404 });
  if (!report.compiled_at) return NextResponse.json({ error: 'report not compiled yet' }, { status: 409 });

  const html = renderReportHtml(
    report.payload as ReportPayload,
    (report.overrides ?? {}) as ReportOverrides,
    { practiceName: practice?.name ?? '', accentHex: practice?.accent_hex ?? null, logo: practice?.logo_url ?? null },
  );
  return new NextResponse(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'X-Content-Type-Options': 'nosniff' },
  });
}
