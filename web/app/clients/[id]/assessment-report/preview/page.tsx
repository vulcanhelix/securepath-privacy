import { redirect } from 'next/navigation';
import { Badge } from '@/components/ui/Badge';
import { PageHeader } from '@/components/ui/PageHeader';
import { serverClient } from '@/lib/supabase';
import ReportViewer from './report-viewer';

export const dynamic = 'force-dynamic';

export default async function AssessmentReportPreview({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ report?: string }>;
}) {
  const { id } = await params;
  const reportId = (await searchParams).report;
  if (!reportId) redirect(`/clients/${id}/assessment-report`);

  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const [{ data: client }, { data: report }] = await Promise.all([
    supabase.from('client_orgs').select('name').eq('id', id).maybeSingle(),
    supabase.from('assessment_reports')
      .select('id, title, version, approval_status, framework_key, compiled_at')
      .eq('id', reportId)
      .eq('client_org_id', id)
      .maybeSingle(),
  ]);
  if (!client || !report?.compiled_at) redirect(`/clients/${id}/assessment-report`);

  const frameworkQuery = report.framework_key === 'popia' ? '' : `?framework=${report.framework_key}`;
  const previewSrc = `/api/clients/${id}/assessment-report/preview?report=${report.id}`;

  return (
    <>
      <PageHeader
        title={`${client.name} — ${report.title}`}
        back="Assessment reports"
        backHref={`/clients/${id}/assessment-report${frameworkQuery}`}
        meta="Review the client deliverable in the SecurePath workspace, then download the print-formatted A4 PDF."
        actions={
          <>
            <Badge><span className="mono">v{report.version}</span></Badge>
            <Badge tone={report.approval_status === 'issued' ? 'ink' : 'neutral'}>
              {report.approval_status.replace(/_/g, ' ')}
            </Badge>
          </>
        }
      />
      <ReportViewer src={previewSrc} title={`${client.name} assessment report v${report.version}`} />
    </>
  );
}
