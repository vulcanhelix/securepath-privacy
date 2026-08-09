import { NextResponse, type NextRequest } from 'next/server';
import { serverClient } from '@/lib/supabase';
import { conversationAdapter } from '@/lib/ai/adapter';
import { activeQuestion, confirmedAnswer, isClassificationInput, nextFollowUp, nextQuestion, pendingFindingsDraft, pendingProposalResponse, phaseFor, proposalConfirmation, resolveIntent, type CanonicalAnswer, type EngineQuestion, type EngineResponse, type EngineTurn, type Phase } from '@/lib/ai/engine';

type Question = EngineQuestion & { section_id: number; section_name: string; question_number: number; risk: string };
type ChatState = { supabase: Awaited<ReturnType<typeof serverClient>>; session: Record<string, unknown>; turns: EngineTurn[]; responses: EngineResponse[]; questions: Question[]; documents: Array<{ id: string; original_filename: string; mime: string; size: number; question_id: string | null; question?: string; created_at: string }> };
type ChatKind = 'question' | 'answer' | 'proposal' | 'explainer' | 'upload' | 'summary' | 'navigation' | 'gap_details' | 'owner' | 'target_date' | 'evidence';

async function getState(supabase: ChatState['supabase'], id: string): Promise<ChatState> {
  const [{ data: session, error: sessionError }, { data: turns }, { data: responses }, { data: documents }] = await Promise.all([
    supabase.from('assessment_sessions').select('id, client_org_id, framework, title, status, score_pct, rating').eq('id', id).single(),
    supabase.from('assessment_chat_turns').select('id, role, kind, content, question_id, created_at').eq('session_id', id).order('created_at'),
    supabase.from('assessment_responses').select('question_id, response, findings, responsible_party, target_date').eq('session_id', id),
    supabase.from('assessment_documents').select('id, original_filename, mime, size, question_id, created_at').eq('session_id', id).order('created_at'),
  ]);
  if (sessionError || !session) throw new Error('Assessment not found');
  const { data: questions } = await supabase.from('assessment_questions')
    .select('id, section_id, section_name, question_number, question, why_matters, regulatory_ref, evidence_req, remediation, risk')
    .eq('framework', session.framework).eq('active', true).order('section_id').order('question_number');
  const qs = (questions ?? []) as Question[];
  return { supabase, session, turns: (turns ?? []) as EngineTurn[], responses: (responses ?? []) as EngineResponse[], questions: qs, documents: (documents ?? []).map(document => ({ ...document, question: qs.find(question => question.id === document.question_id)?.question })) };
}

function prompt(question: Question, sameSection = false) {
  return sameSection ? question.question : `Let's look at ${question.section_name}. ${question.question}`;
}

async function roleOf(supabase: ChatState['supabase'], userId: string | undefined) {
  if (!userId) return null;
  const { data } = await supabase.from('memberships').select('role').eq('user_id', userId).maybeSingle();
  return data?.role ?? null;
}

async function conversationalPrompt(id: string, question: Question, turns: EngineTurn[], questions: Question[] = []) {
  const asked = [...turns].reverse().find(turn => turn.role === 'assistant' && turn.kind === 'question' && turn.question_id === question.id);
  if (asked) return asked.content;
  const previous = [...turns].reverse().find(turn => turn.role === 'assistant' && turn.kind === 'question' && turn.question_id);
  const sameSection = questions.find(item => item.id === previous?.question_id)?.section_id === question.section_id;
  const model = await conversationAdapter.generate({ task: 'question', sessionId: id, question, userInput: '', turns });
  return model?.message || prompt(question, sameSection);
}

function followUpPrompt(question: Question, phase: Phase) {
  if (phase === 'gap_details') return 'What is currently in place, and why is this control only partial or not in place?';
  if (phase === 'owner') return 'Who owns this control? A person, role, or team is fine.';
  if (phase === 'target_date') return 'What target date should we use for closing this gap? Use YYYY-MM-DD.';
  if (phase === 'evidence') return `Do you have this evidence available to upload? ${question.evidence_req}`;
  return prompt(question);
}

function progress(s: ChatState, question: Question | null) {
  const sections = [...new Set(s.questions.map(q => q.section_id))];
  const answered = new Set(s.responses.map(response => response.question_id)).size;
  const index = question ? s.questions.findIndex(item => item.id === question.id) : -1;
  return {
    question_number: index >= 0 ? index + 1 : question ? Math.min(answered + 1, s.questions.length) : s.questions.length,
    question_total: s.questions.length,
    module_number: question ? sections.indexOf(question.section_id) + 1 : sections.length,
    module_total: sections.length,
  };
}

function presentTurns(s: ChatState) {
  return s.turns.map(turn => ({
    ...turn,
    evidence_req: turn.question_id ? s.questions.find(question => question.id === turn.question_id)?.evidence_req ?? null : null,
  }));
}

export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await serverClient();
  try {
    const initial = await getState(supabase, id);
    const { data: { user } } = await supabase.auth.getUser();
    const { data: membership } = user
      ? await supabase.from('memberships').select('role').eq('user_id', user.id).maybeSingle()
      : { data: null };
    if (!initial.turns.length && membership?.role !== 'read_only') {
      await supabase.rpc('ensure_assessment_chat_opening', { p_session_id: id });
    }
    const s = initial.turns.length ? initial : await getState(supabase, id);
    const next = activeQuestion(s.questions, s.responses, s.turns);
    const nextPrompt = next ? await conversationalPrompt(id, next, s.turns, s.questions) : null;
    return NextResponse.json({
      session: s.session,
      turns: presentTurns(s),
      next: next ? { ...next, prompt: nextPrompt, phase: phaseFor(next.id, s.turns) } : null,
      documents: s.documents,
      progress: progress(s, next),
      can_write: membership?.role !== 'read_only',
    });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : 'Unable to load chat' }, { status: 404 });
  }
}

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const body = await req.json() as { content?: string; question_id?: string };
  const supabase = await serverClient();
  const s = await getState(supabase, id);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  if (await roleOf(supabase, user.id) === 'read_only') {
    return NextResponse.json({ error: 'Your role has read-only access to this assessment.' }, { status: 403 });
  }
  const requested = body.question_id ? s.questions.find(item => item.id === body.question_id) : null;
  const requestedPhase = requested ? phaseFor(requested.id, s.turns) : null;
  const q = requested && (requestedPhase !== 'answer' || !s.responses.some(response => response.question_id === requested.id))
    ? requested
    : activeQuestion(s.questions, s.responses, s.turns);
  const content = body.content?.trim() ?? '';
  if (!content) return NextResponse.json({ error: 'message is required' }, { status: 400 });
  if (!q) return NextResponse.json({ error: 'assessment is complete' }, { status: 400 });
  const phase: Phase = phaseFor(q.id, s.turns);
  const pendingClassification = pendingProposalResponse(s.turns, q.id);
  const pendingDraft = pendingFindingsDraft(s.turns, q.id);
  const action = proposalConfirmation(content);
  const baseIntent = resolveIntent(content, phase);
  const intent = pendingClassification && action === 'confirm'
    ? { type: 'confirm' as const, response: pendingClassification, prose: content }
    : baseIntent;
  const append = async (role: 'user' | 'assistant', kind: ChatKind, text: string, questionId?: string) => {
    const { error } = await supabase.rpc('append_assessment_chat_turn', { p_session_id: id, p_role: role, p_kind: kind, p_content: text, p_question_id: questionId ?? null });
    if (error) throw new Error(error.message);
  };
  const reply = async (kind: ChatKind, text: string, questionId = q.id, stayOnQuestion = false) => {
    await append('assistant', kind, text, questionId);
    const updated = { ...s, turns: [...s.turns, { role: 'assistant', kind, content: text, question_id: questionId }] };
    const next = stayOnQuestion ? q : nextQuestion(updated.questions, updated.responses, updated.turns) as Question | null;
    const nextPrompt = next && !stayOnQuestion ? await conversationalPrompt(id, next, updated.turns, updated.questions) : null;
    return NextResponse.json({
      turns: [{ role: 'assistant', kind, content: text, question_id: questionId }],
      next: next ? { ...next, prompt: nextPrompt, phase: phaseFor(next.id, updated.turns) } : null,
      documents: updated.documents,
      progress: progress(updated, next),
    });
  };

  const alreadyDeferred = s.turns.some(turn => turn.question_id === q.id && turn.kind === 'navigation' && turn.content === '[deferred]');
  const userKind: ChatKind = ['skip', 'leave_blank', 'back'].includes(intent.type) ? 'navigation' : intent.type === 'explain' || intent.type === 'example' ? 'explainer' : phase === 'answer' && (intent.type === 'answer' || intent.type === 'confirm') ? 'answer' : phase;
  const userContent = intent.type === 'leave_blank'
    ? '[deferred-final]'
    : intent.type === 'skip' && phase === 'answer' && alreadyDeferred
      ? '[deferred-again]'
      : intent.type === 'skip' && phase === 'answer'
        ? '[deferred]'
        : intent.type === 'skip'
          ? '[skipped-follow-up]'
        : content;
  await append('user', userKind, userContent, q.id);
  s.turns = [...s.turns, { role: 'user', kind: userKind, content: userContent, question_id: q.id }];
  if (intent.type === 'explain') {
    const response = s.responses.find(item => item.question_id === q.id);
    const model = await conversationAdapter.generate({ task: 'explain', sessionId: id, question: q, userInput: content, turns: s.turns });
    return reply('explainer', model?.message ?? conversationAdapter.render('explainer', { why: q.why_matters, regulatory_ref: q.regulatory_ref, remediation: response && ['partial', 'non_compliant'].includes(response.response) ? q.remediation : null }), q.id, true);
  }
  if (intent.type === 'example') {
    const model = await conversationAdapter.generate({ task: 'explain', sessionId: id, question: q, userInput: content, turns: s.turns });
    return reply('explainer', model?.message ?? conversationAdapter.render('example', { evidence: q.evidence_req }), q.id, true);
  }
  if (intent.type === 'back' && phase !== 'answer') return reply(phase, `Let's stay with this step. ${followUpPrompt(q, phase)}`, q.id, true);
  if (intent.type === 'leave_blank') {
    if (!alreadyDeferred) return reply('navigation', 'I can leave this blank after you defer it once. Say “skip” first, then “leave blank” if you want to finish without answering.', q.id, true);
    return finishOrAdvance(s, append);
  }
  if (intent.type === 'skip' && phase !== 'answer') return finishOrAdvance(s, append);
  if (phase === 'answer') {
    if (pendingClassification && action === 'rephrase') return reply('question', 'No problem. Tell me a little more about the control in your own words, and I’ll reconsider it.', q.id, true);
    if (intent.type === 'uncertain') return reply('question', `No problem. We can take this one step at a time. What do you know about whether ${q.question.toLowerCase()}? You can describe what is in place, even if it is incomplete.`);
    if (intent.type === 'unrecognised') {
      const model = await conversationAdapter.generate({ task: 'classify', sessionId: id, question: q, userInput: content, turns: s.turns });
      if (model?.response) {
        const proposal = `${withoutConfirmInstruction(model.message)}\n\nProposed classification: ${model.response}. Choose “Yes, that’s right” to record it, or “No, let me rephrase” — or reply “confirm ${model.response}”.`;
        return reply('proposal', proposal, q.id, true);
      }
      return reply('question', `Thanks — I heard: “${content}”. Is that control fully in place, partly in place, not in place, or not applicable? You can answer in your own words.`);
    }
    if (intent.type === 'back') {
      const previous = s.questions.filter(item => s.responses.some(response => response.question_id === item.id)).at(-1) ?? q;
      return reply('navigation', previous ? `Let's revisit this one: ${prompt(previous)}` : 'We are at the beginning of the assessment.', previous?.id);
    }
    if (intent.type === 'skip') {
      return reply('navigation', alreadyDeferred
        ? `You already deferred this question. If you want to leave it unanswered, say “leave blank”. Otherwise, answer it now.`
        : `I’ll come back to “${q.question}” before we wrap up.`, q.id, alreadyDeferred);
    }
    if (intent.type === 'answer' || intent.type === 'confirm') {
      const answer = intent.response as CanonicalAnswer;
      if (intent.type === 'confirm' && confirmedAnswer(intent, s.turns, q.id) !== answer) {
        return reply('question', 'I do not have a matching classification proposal waiting. Please describe the control again and I will help classify it.', q.id, true);
      }
      const { error: clearError } = await supabase.rpc('clear_assessment_response_followups', { p_session_id: id, p_question_id: q.id });
      if (clearError) return NextResponse.json({ error: clearError.message }, { status: 400 });
      const { error } = await supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: answer, p_findings: null, p_responsible_party: null, p_target_date: null, p_status: answer === 'na' ? 'na' : 'complete' });
      if (error) return NextResponse.json({ error: error.message }, { status: 400 });
      s.responses = [...s.responses.filter(response => response.question_id !== q.id), { question_id: q.id, response: answer, findings: null, responsible_party: null, target_date: null }];
      const firstFollowUp = nextFollowUp(q, answer, phase);
      if (firstFollowUp === 'gap_details') return reply('gap_details', 'What is currently in place, and why is this control only partial or not in place?', q.id, true);
      if (firstFollowUp === 'evidence') return reply('evidence', `Do you have this evidence available to upload? ${q.evidence_req}`, q.id, true);
      return finishOrAdvance(s, append);
    }
  } else if (phase === 'gap_details') {
    const response = s.responses.find(item => item.question_id === q.id);
    if (!response) return reply('question', 'Please answer the control first, then we can capture the gap details.');
    if (isClassificationInput(content) && !(pendingDraft && action)) return reply('gap_details', `That is an answer to the control itself, which is already recorded as ${response.response}. ${followUpPrompt(q, phase)}`, q.id, true);
    if (pendingDraft && action === 'confirm') {
      const { error } = await supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: response.response, p_findings: pendingDraft, p_responsible_party: response.responsible_party ?? null, p_target_date: response.target_date ?? null, p_status: 'in_progress' });
      if (error) return NextResponse.json({ error: error.message }, { status: 400 });
      response.findings = pendingDraft;
      return reply('owner', 'Thanks — I’ll record that. Who owns this control? A person, role, or team is fine.', q.id, true);
    }
    if (pendingDraft && action === 'rephrase') return reply('gap_details', 'No problem. Tell me what is in place and what is missing, in your own words.', q.id, true);
    const findings = await conversationAdapter.generate({ task: 'findings', sessionId: id, question: q, userInput: content, turns: s.turns });
    if (findings?.draft) {
      return reply('proposal', `Draft findings: ${findings.draft}\n\n${findings.message}\n\nPlease choose “Yes, that’s right” to save this, or “No, let me rephrase”.`, q.id, true);
    }
    await supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: response.response, p_findings: content, p_responsible_party: response.responsible_party ?? null, p_target_date: response.target_date ?? null, p_status: 'in_progress' });
    response.findings = content;
    return reply('owner', 'Who owns this control? A person, role, or team is fine.', q.id, true);
  } else if (phase === 'owner') {
    const response = s.responses.find(item => item.question_id === q.id);
    if (isClassificationInput(content)) return reply('owner', `That is an answer to the control itself, not an owner. ${followUpPrompt(q, phase)}`, q.id, true);
    if (response) await supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: response.response, p_findings: response.findings ?? null, p_responsible_party: content, p_target_date: response.target_date ?? null, p_status: 'in_progress' });
    if (response) response.responsible_party = content;
    return reply('target_date', 'What target date should we use for closing this gap? Use YYYY-MM-DD.', q.id, true);
  } else if (phase === 'target_date') {
    if (isClassificationInput(content)) return reply('target_date', `That is an answer to the control itself, not a date. ${followUpPrompt(q, phase)}`, q.id, true);
    const date = content.match(/\b20\d\d-\d\d-\d\d\b/)?.[0];
    if (!date || Number.isNaN(Date.parse(date))) return reply('target_date', 'Please give me a valid target date in YYYY-MM-DD format.', q.id, true);
    const response = s.responses.find(item => item.question_id === q.id);
    if (response) await supabase.rpc('upsert_response', { p_session_id: id, p_question_id: q.id, p_response: response.response, p_findings: response.findings ?? null, p_responsible_party: response.responsible_party ?? null, p_target_date: date, p_status: 'complete' });
    if (response) response.target_date = date;
    if (q.evidence_req) return reply('evidence', `Do you have this evidence available to upload? ${q.evidence_req}`, q.id, true);
    return finishOrAdvance(s, append);
  } else if (phase === 'evidence') {
    if (isClassificationInput(content)) return reply('evidence', `That is an answer to the control itself, which is already recorded. ${followUpPrompt(q, phase)} Upload a file, or say “no” to move on.`, q.id, true);
    return finishOrAdvance(s, append);
  }
  return reply('question', `Tell me a little more about ${q.question.toLowerCase()}.`);
}

// The model is told to ask for "confirm <classification>"; the route appends its own
// confirmation instruction, so drop the model's version rather than saying it twice.
function withoutConfirmInstruction(message: string) {
  return message
    .split(/(?<=[.!?])\s+/)
    .filter(sentence => !/confirm/i.test(sentence))
    .join(' ')
    .trim() || message;
}

async function finishOrAdvance(s: ChatState, append: (role: 'user' | 'assistant', kind: ChatKind, text: string, questionId?: string) => Promise<void>) {
  const next = nextQuestion(s.questions, s.responses, s.turns) as Question | null;
  if (!next) {
    const remediation = s.responses.filter(r => r.response === 'non_compliant').map(r => s.questions.find(question => question.id === r.question_id)?.remediation).filter(Boolean);
    const { data: latestSession } = await s.supabase.from('assessment_sessions').select('score_pct').eq('id', s.session.id).single();
    const summary = `Assessment complete. Your current score is ${latestSession?.score_pct ?? s.session.score_pct ?? 0}%.\n\nRemediation to-dos:\n${remediation.length ? remediation.map(item => `• ${item}`).join('\n') : '• No non-compliant controls recorded.'}`;
    await append('assistant', 'summary', summary);
    await s.supabase.rpc('update_assessment', { p_id: s.session.id, p_title: null, p_org_name: null, p_auditor_name: null, p_audit_date: null, p_audit_ref: null, p_status: 'complete' });
    return NextResponse.json({ turns: [{ role: 'assistant', kind: 'summary', content: summary }], next: null, complete: true, documents: s.documents, progress: progress(s, null) });
  }
  const text = await conversationalPrompt(String(s.session.id), next, s.turns, s.questions);
  await append('assistant', 'question', text, next.id);
  return NextResponse.json({ turns: [{ role: 'assistant', kind: 'question', content: text, question_id: next.id }], next: { ...next, prompt: text }, documents: s.documents, progress: progress(s, next) });
}
