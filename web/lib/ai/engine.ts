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

function canonicalAnswerFromToken(token: string): CanonicalAnswer | null {
  const normalized = token.trim().toLowerCase().replace(/[\/ -]+/g, '_');
  if (normalized === 'fully_compliant') return 'fully_compliant';
  if (normalized === 'partial') return 'partial';
  if (normalized === 'non_compliant') return 'non_compliant';
  if (normalized === 'na' || normalized === 'n_a') return 'na';
  return null;
}

export function resolveIntent(input: string, phase: Phase = 'answer'): ResolvedIntent {
  const prose = input.trim();
  const lower = prose.toLowerCase();
  if (/^(explain|why)\b/.test(lower)) return { type: 'explain', prose };
  if (/^(example|sample)\b/.test(lower)) return { type: 'example', prose };
  if (/^(leave blank|leave unanswered|leave it blank)\b/.test(lower)) return { type: 'leave_blank', prose };
  if (/^(skip|defer|later)\b/.test(lower)) return { type: 'skip', prose };
  if (/^(back|previous)\b/.test(lower)) return { type: 'back', prose };
  if (phase !== 'answer') return { type: 'unrecognised', prose };
  if (/^(fully_compliant|partial|non_compliant|na)$/i.test(prose)) {
    return { type: 'answer', response: canonicalAnswerFromToken(prose) as CanonicalAnswer, prose };
  }
  const confirmation = lower.match(/^confirm\s+(fully[- _]?compliant|partial|non[- _]?compliant|na|n\/a)\s*$/);
  if (confirmation) {
    const response = canonicalAnswerFromToken(confirmation[1]);
    if (response) return { type: 'confirm', response, prose };
  }
  if (/^(i don['’]?t know|not sure|unsure|no idea|i['’]?m unsure)\b/.test(lower)) return { type: 'uncertain', prose };
  for (const [pattern, response] of canonical) if (pattern.test(prose)) return { type: 'answer', response, prose };
  return { type: 'unrecognised', prose };
}

const chipPhrases = /^(yes,? that'?s right|no,? let me rephrase)$/i;

// Quick-reply tokens are answers to the classification question only. They must never be
// stored as findings, owner, or target-date free text when a follow-up phase is active.
export function isClassificationInput(input: string): boolean {
  const prose = input.trim();
  if (chipPhrases.test(prose)) return true;
  if (canonicalAnswerFromToken(prose)) return true;
  const confirmation = prose.toLowerCase().match(/^confirm\s+(fully[- _]?compliant|partial|non[- _]?compliant|na|n\/a)\s*$/);
  return Boolean(confirmation && canonicalAnswerFromToken(confirmation[1]));
}

export function phaseFor(questionId: string, turns: EngineTurn[]): Phase {
  const questionTurns = turns
    .map((turn, index) => ({ turn, index }))
    .filter(item => item.turn.question_id === questionId);
  const latest = questionTurns.at(-1);
  if (latest?.turn.role === 'assistant' && latest.turn.kind === 'upload') {
    const interrupted = questionTurns
      .slice(0, -1)
      .reverse()
      .find(item => item.turn.role === 'assistant' && ['gap_details', 'owner', 'target_date', 'evidence'].includes(item.turn.kind));
    return interrupted?.turn.kind === 'evidence' ? 'answer' : (interrupted?.turn.kind as Phase | undefined) ?? 'answer';
  }
  const last = questionTurns.reverse().find(item => item.turn.role === 'assistant' && ['gap_details', 'owner', 'target_date', 'evidence'].includes(item.turn.kind));
  if (last) return last.turn.kind as Phase;
  return 'answer';
}

export function nextQuestion<Q extends EngineQuestion>(questions: Q[], responses: EngineResponse[], turns: EngineTurn[]): Q | null {
  const answered = new Set(responses.map(response => response.question_id));
  const deferred = new Set(turns.filter(turn => turn.kind === 'navigation' && turn.content === '[deferred]' && turn.question_id).map(turn => turn.question_id as string));
  const leftBlank = new Set(turns.filter(turn => turn.kind === 'navigation' && turn.content === '[deferred-final]' && turn.question_id).map(turn => turn.question_id as string));
  const unanswered = questions.filter(question => !answered.has(question.id) && !leftBlank.has(question.id));
  return unanswered.find(question => !deferred.has(question.id)) ?? unanswered[0] ?? null;
}

// A question with an unfinished follow-up stays current even though it already has a
// response row, so reloading (or uploading evidence) mid-follow-up resumes that phase.
export function activeQuestion<Q extends EngineQuestion>(questions: Q[], responses: EngineResponse[], turns: EngineTurn[]): Q | null {
  const latest = [...turns].reverse().find(turn => turn.role === 'assistant' && turn.question_id);
  if (latest?.question_id && phaseFor(latest.question_id, turns) !== 'answer') {
    const question = questions.find(item => item.id === latest.question_id);
    if (question) return question;
  }
  return nextQuestion(questions, responses, turns);
}

export function proposalConfirmation(input: string): 'confirm' | 'rephrase' | null {
  const lower = input.trim().toLowerCase();
  if (/^(yes|yep|yeah|correct|right|agree|that'?s right|looks good|sounds right|exactly)\b/.test(lower)) return 'confirm';
  if (/^(no|nope|not quite|that'?s not right|let me rephrase|i need to correct)\b/.test(lower)) return 'rephrase';
  return null;
}

export function pendingProposalResponse(turns: EngineTurn[], questionId: string, allowTrailingUser = false): CanonicalAnswer | null {
  const proposal = turns.map((turn, index) => ({ turn, index })).reverse().find(item =>
    item.turn.role === 'assistant' && item.turn.kind === 'proposal' && item.turn.question_id === questionId
  );
  if (!proposal) return null;
  const turnsAfter = turns.slice(proposal.index + 1);
  const userTurnsAfter = turnsAfter.filter(turn => turn.role === 'user');
  if (userTurnsAfter.length > (allowTrailingUser ? 1 : 0)) return null;
  const match = proposal.turn.content.match(/confirm\s+(fully[_ -]?compliant|partial|non[_ -]?compliant|n\/a|na)\b/i);
  if (!match) return null;
  return canonicalAnswerFromToken(match[1]);
}

export function confirmedAnswer(intent: ResolvedIntent, turns: EngineTurn[], questionId: string): CanonicalAnswer | null {
  if (intent.type === 'answer') return intent.response;
  if (intent.type === 'confirm') {
    const proposalIndex = turns.map((turn, index) => ({ turn, index })).reverse().find(item =>
      item.turn.role === 'assistant' && item.turn.kind === 'proposal' && item.turn.question_id === questionId
    )?.index;
    const hasUserConfirmation = proposalIndex !== undefined && turns.slice(proposalIndex + 1).some(turn => turn.role === 'user');
    if (hasUserConfirmation && pendingProposalResponse(turns, questionId, true) === intent.response) return intent.response;
  }
  return null;
}

export function pendingFindingsDraft(turns: EngineTurn[], questionId: string, allowTrailingUser = false): string | null {
  const proposal = turns.map((turn, index) => ({ turn, index })).reverse().find(item =>
    item.turn.role === 'assistant' && item.turn.kind === 'proposal' && item.turn.question_id === questionId &&
    item.turn.content.startsWith('Draft findings:')
  );
  if (!proposal) return null;
  const userTurnsAfter = turns.slice(proposal.index + 1).filter(turn => turn.role === 'user');
  if (userTurnsAfter.length > (allowTrailingUser ? 1 : 0)) return null;
  const draft = proposal.turn.content.match(/^Draft findings:\s*([\s\S]*?)(?:\n\n|$)/i)?.[1]?.trim();
  return draft || null;
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
