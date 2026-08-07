import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { conversationAdapter, type Intent } from '@/lib/ai/adapter';

type Question = { id: string; section_id: number; section_name: string; question_number: number; question: string; why_matters: string | null; evidence_req: string | null; remediation: string | null; risk: string };
const answerValues = ['fully_compliant', 'partial', 'non_compliant', 'na'] as const;

async function state(id: string) {
  const supabase = await serverClient();
  const [{ data: session, error: sessionError }, { data: turns }, { data: responses }] = await Promise.all([
    supabase.from('assessment_sessions').select('id, client_org_id, framework, title, status, score_pct, rating').eq('id', id).single(),
    supabase.from('assessment_chat_turns').select('*').eq('session_id', id).order('created_at'),
    supabase.from('assessment_responses').select('question_id, response, findings, responsible_party, target_date').eq('session_id', id),
  ]);
  if (sessionError || !session) throw new Error('Assessment not found');
  const { data: questions } = await supabase.from('assessment_questions').select('id, section_id, section_name, question_number, question, why_matters, evidence_req, remediation, risk').eq('framework', session.framework).eq('active', true).order('section_id').order('question_number');
  const qs = (questions ?? []) as Question[];
  const answered = new Set((responses ?? []).map(r => r.question_id));
  const next = qs.find(q => !answered.has(q.id)) ?? null;
  return { supabase, session, turns: turns ?? [], responses: responses ?? [], questions: qs, next };
}

function questionText(q: Question) {
  return `Let's look at ${q.section_name}. ${q.question}`;
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { id } = await params;
    const s = await state(id);
    return NextResponse.json({ session: s.session, turns: s.turns, next: s.next ? { ...s.next, prompt: questionText(s.next) } : null });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : 'Unable to load chat' }, { status: 404 });
  }
}

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = await req.json() as { content?: string; intent?: Intent['type']; response?: typeof answerValues[number]; question_id?: string; responsible_party?: string; target_date?: string };
  const s = await state(id);
  const { data: { user } } = await s.supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  const content = body.content?.trim() || body.response || '';
  if (!content) return NextResponse.json({ error: 'message is required' }, { status: 400 });
  const intent = body.intent ? ({ type: body.intent } as Intent) : conversationAdapter.detectIntent(content);
  const q = body.question_id ? s.questions.find(item => item.id === body.question_id) : s.next;
  const append = async (role: 'user' | 'assistant', kind: 'question' | 'answer' | 'explainer' | 'summary' | 'navigation', text: string, questionId?: string) => {
    const { error } = await s.supabase.rpc('append_assessment_chat_turn', { p_session_id: id, p_role: role, p_kind: kind, p_content: text, p_question_id: questionId ?? null });
    if (error) throw new Error(error.message);
  };
  await append('user', intent.type === 'answer' ? 'answer' : 'navigation', content, q?.id);

  if (intent.type === 'explain' && q) {
    const text = conversationAdapter.render('explainer', { why: q.why_matters });
    await append('assistant', 'explainer', text, q.id);
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'explainer', content: text, question_id: q.id }], next: q });
  }
  if (intent.type === 'example' && q) {
    const text = conversationAdapter.render('example', { evidence: q.evidence_req });
    await append('assistant', 'explainer', text, q.id);
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'explainer', content: text, question_id: q.id }], next: q });
  }
  if ((intent.type === 'owner' || intent.type === 'target_date' || intent.type === 'unknown') && q) {
    const text = intent.type === 'owner' ? 'Who owns this control? You can name a person, role, or team.' : intent.type === 'target_date' ? 'What target date should we use for closing this gap? Use YYYY-MM-DD.' : 'That is okay — you can choose an answer above, ask me to explain it, or say “example”.';
    await append('assistant', 'question', text, q.id);
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'question', content: text, question_id: q.id }], next: q });
  }
  if (intent.type === 'back') {
    const previous = s.questions.filter(item => s.responses.some(r => r.question_id === item.id)).at(-1) ?? q;
    const text = previous ? `Let's revisit this one: ${questionText(previous)}` : 'We are at the beginning of the assessment.';
    await append('assistant', 'navigation', text, previous?.id);
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'navigation', content: text, question_id: previous?.id }], next: previous });
  }
  if (intent.type === 'skip' && q) {
    await s.supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: 'na', p_findings: 'Skipped in chat', p_responsible_party: null, p_target_date: null, p_status: 'na' });
  } else if (intent.type === 'answer' && q && answerValues.includes(intent.response)) {
    const needsGap = intent.response === 'partial' || intent.response === 'non_compliant';
    const findings = needsGap ? content : null;
    const { error } = await s.supabase.rpc('upsert_response', {
      p_session_id: id, p_question_id: q.id, p_response: intent.response, p_findings: findings,
      p_responsible_party: body.responsible_party ?? null, p_target_date: body.target_date ?? null,
      p_status: intent.response === 'na' ? 'na' : 'complete',
    });
    if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  }
  const latest = await state(id);
  if (!latest.next) {
    const remediation = latest.responses
      .filter(r => r.response === 'non_compliant')
      .map(r => latest.questions.find(q => q.id === r.question_id)?.remediation)
      .filter(Boolean);
    const summary = `${conversationAdapter.render('summary', { completed: latest.responses.length, total: latest.questions.length, score: latest.session.score_pct ?? 0 })}\n\nRemediation to-dos:\n${remediation.length ? remediation.map(item => `• ${item}`).join('\n') : '• No non-compliant controls recorded.'}`;
    await append('assistant', 'summary', summary, undefined);
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'summary', content: summary }], next: null, complete: true, remediation });
  }
  const prompt = questionText(latest.next);
  await append('assistant', 'question', prompt, latest.next.id);
  return NextResponse.json({ turns: [{ role: 'assistant', kind: 'question', content: prompt, question_id: latest.next.id }], next: latest.next });
}
