export type CanonicalAnswer = 'fully_compliant' | 'partial' | 'non_compliant' | 'na';
export type Phase = 'answer' | 'gap_details' | 'owner' | 'target_date' | 'evidence';
export type EngineQuestion = { id: string; section_id: number; section_name: string; question: string; evidence_req?: string | null; why_matters?: string | null; regulatory_ref?: string | null; remediation?: string | null };
export type EngineResponse = { question_id: string; response: CanonicalAnswer; findings?: string | null; responsible_party?: string | null; target_date?: string | null };
export type EngineTurn = { role: string; kind: string; content: string; question_id?: string | null };

export type ResolvedIntent =
  | { type: 'answer'; response: CanonicalAnswer; prose: string }
  | { type: 'confirm'; response: CanonicalAnswer; prose: string }
  | { type: 'explain' | 'example' | 'skip' | 'back' | 'leave_blank' | 'uncertain' | 'unrecognised'; prose: string };

const canonical: Array<[RegExp, CanonicalAnswer]> = [
  [/\b(not applicable|n\/a|doesn['’]t apply)\b/i, 'na'],
  [/\b(non[- _]?compliant|not compliant|no policy|no control|not in place)\b/i, 'non_compliant'],
  [/\b(?:no|do not|don't|does not|doesn't)\s+(?:we|i|the|have|use|maintain|there|one)\b/i, 'non_compliant'],
  [/\b(partial(?:ly)?|partly|somewhat|in progress)\b/i, 'partial'],
  [/\b(fully[- _]?compliant|compliant|yes|in place|we have (?:a|the))\b/i, 'fully_compliant'],
];

export function resolveIntent(input: string, phase: Phase = 'answer'): ResolvedIntent {
  const prose = input.trim();
  const lower = prose.toLowerCase();
  if (/^(explain|why)\b/.test(lower)) return { type: 'explain', prose };
  if (/^(example|sample)\b/.test(lower)) return { type: 'example', prose };
  if (/^(leave blank|leave unanswered|leave it blank)\b/.test(lower)) return { type: 'leave_blank', prose };
  if (/^(skip|defer|later)\b/.test(lower)) return { type: 'skip', prose };
  if (/^(back|previous)\b/.test(lower)) return { type: 'back', prose };
  if (phase !== 'answer') return { type: 'unrecognised', prose };
  const confirmation = lower.match(/^confirm\s+(fully[- _]?compliant|partial|non[- _]?compliant|na|n\/a)\s*$/);
  if (confirmation) {
    const response = confirmation[1].replace(/[- ]/g, '_') === 'n_a' ? 'na' : confirmation[1].replace(/[- ]/g, '_') as CanonicalAnswer;
    return { type: 'confirm', response, prose };
  }
  if (/^(i don['’]?t know|not sure|unsure|no idea|i['’]?m unsure)\b/.test(lower)) return { type: 'uncertain', prose };
  for (const [pattern, response] of canonical) if (pattern.test(prose)) return { type: 'answer', response, prose };
  return { type: 'unrecognised', prose };
}

export function phaseFor(questionId: string, turns: EngineTurn[]): Phase {
  const latest = [...turns].reverse().find(turn => turn.question_id === questionId);
  if (latest?.role === 'assistant' && latest.kind === 'upload') return 'answer';
  const last = [...turns].reverse().find(turn => turn.question_id === questionId && turn.role === 'assistant' && ['gap_details', 'owner', 'target_date', 'evidence'].includes(turn.kind));
  if (last) return last.kind as Phase;
  return 'answer';
}

export function nextQuestion(questions: EngineQuestion[], responses: EngineResponse[], turns: EngineTurn[]) {
  const answered = new Set(responses.map(response => response.question_id));
  const deferred = new Set(turns.filter(turn => turn.kind === 'navigation' && turn.content === '[deferred]' && turn.question_id).map(turn => turn.question_id as string));
  const leftBlank = new Set(turns.filter(turn => turn.kind === 'navigation' && turn.content === '[deferred-final]' && turn.question_id).map(turn => turn.question_id as string));
  const unanswered = questions.filter(question => !answered.has(question.id) && !leftBlank.has(question.id));
  return unanswered.find(question => !deferred.has(question.id)) ?? unanswered[0] ?? null;
}

export function pendingProposalResponse(turns: EngineTurn[], questionId: string): CanonicalAnswer | null {
  const proposal = turns.map((turn, index) => ({ turn, index })).reverse().find(item =>
    item.turn.role === 'assistant' && item.turn.kind === 'proposal' && item.turn.question_id === questionId
  );
  if (!proposal || turns.slice(proposal.index + 1).some(turn => turn.role === 'user')) return null;
  const match = proposal.turn.content.match(/confirm\s+(fully[_ -]?compliant|partial|non[_ -]?compliant|n\/a|na)\b/i);
  if (!match) return null;
  const normalized = match[1].toLowerCase().replace(/[- ]/g, '_');
  return normalized === 'n_a' || normalized === 'na' ? 'na' : normalized as CanonicalAnswer;
}

export function confirmedAnswer(intent: ResolvedIntent, turns: EngineTurn[], questionId: string): CanonicalAnswer | null {
  if (intent.type === 'answer') return intent.response;
  if (intent.type === 'confirm' && pendingProposalResponse(turns, questionId) === intent.response) return intent.response;
  return null;
}

export function followUpFor(question: EngineQuestion, response: CanonicalAnswer): Phase | null {
  if (response === 'partial' || response === 'non_compliant') return 'gap_details';
  if (response === 'fully_compliant' && question.evidence_req) return 'evidence';
  return null;
}

export function nextFollowUp(question: EngineQuestion, response: CanonicalAnswer, phase: Phase): Phase | null {
  if (phase === 'answer') return followUpFor(question, response);
  if (phase === 'gap_details') return 'owner';
  if (phase === 'owner') return 'target_date';
  if (phase === 'target_date') return question.evidence_req ? 'evidence' : null;
  return null;
}
