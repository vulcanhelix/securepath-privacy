import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import ChatAssessment from './ChatAssessment';

export default async function AssessmentChatPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');
  const { data: assessment } = await supabase.from('assessment_sessions').select('id, title').eq('id', id).single();
  if (!assessment) return <div className="card"><p>Assessment not found.</p></div>;
  return (
    <>
      <div className="chat-heading"><Link href={`/assessments/${id}`}>← Grid editor</Link><h1>{assessment.title}</h1><span className="badge">Conversation mode</span></div>
      <ChatAssessment assessmentId={id} />
    </>
  );
}
