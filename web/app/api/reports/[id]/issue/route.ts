import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'crypto';
import { serverClient } from '@/lib/supabase';
import { putObject } from '@/lib/storage';

// Approve-and-issue: render the report to an immutable archived document, then issue.
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });

  const { data: report } = await supabase
    .from('monthly_reports').select('client_org_id, title, body, version, period, approval_status').eq('id', id).maybeSingle();
  if (!report) return NextResponse.json({ error: 'not found' }, { status: 404 });

  const bytes = new TextEncoder().encode(report.body);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const key = `${report.client_org_id}/report-${report.period}-${id}.md`;
  await putObject(key, bytes, 'text/markdown');

  const { data: docId, error } = await supabase.rpc('issue_monthly_report', {
    p_report_id: id, p_storage_path: key, p_sha256: sha256, p_size: bytes.length,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 403 });
  return NextResponse.json({ document_id: docId });
}
