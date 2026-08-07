export type Intent =
  | { type: 'answer'; response: 'fully_compliant' | 'partial' | 'non_compliant' | 'na' }
  | { type: 'explain' | 'example' | 'skip' | 'back' | 'owner' | 'target_date' | 'unknown' };

export interface ConversationAdapter {
  detectIntent(input: string): Intent;
  render(kind: 'question' | 'explainer' | 'example' | 'prompt' | 'summary', data: Record<string, unknown>): string;
}

const answerWords: Record<string, Intent> = {
  yes: { type: 'answer', response: 'fully_compliant' }, compliant: { type: 'answer', response: 'fully_compliant' },
  fully: { type: 'answer', response: 'fully_compliant' }, partial: { type: 'answer', response: 'partial' },
  partly: { type: 'answer', response: 'partial' }, no: { type: 'answer', response: 'non_compliant' },
  non: { type: 'answer', response: 'non_compliant' }, gap: { type: 'answer', response: 'non_compliant' },
  fully_compliant: { type: 'answer', response: 'fully_compliant' },
  non_compliant: { type: 'answer', response: 'non_compliant' },
  'not applicable': { type: 'answer', response: 'na' }, na: { type: 'answer', response: 'na' },
  'n/a': { type: 'answer', response: 'na' },
};

export const noneAdapter: ConversationAdapter = {
  detectIntent(input) {
    const text = input.trim().toLowerCase();
    if (answerWords[text]) return answerWords[text];
    if (/\b(explain|why)\b/.test(text)) return { type: 'explain' };
    if (/\b(example|sample)\b/.test(text)) return { type: 'example' };
    if (/\b(skip|defer|later)\b/.test(text)) return { type: 'skip' };
    if (/\b(back|previous)\b/.test(text)) return { type: 'back' };
    if (/^(i don['’]?t know|not sure|unsure|no idea)\b/.test(text)) return { type: 'unknown' };
    return { type: 'unknown' };
  },
  render(kind, data) {
    const q = String(data.question ?? '');
    if (kind === 'explainer') {
      const reference = data.regulatory_ref ? ` It relates to ${data.regulatory_ref}.` : '';
      const remediation = data.remediation ? ` If there is a gap, a useful next step is: ${data.remediation}` : '';
      return `This matters because ${data.why ?? 'it helps demonstrate that your privacy controls are operating in practice.'}${reference}${remediation}`;
    }
    if (kind === 'example') return `For example: ${data.evidence ?? 'a policy, register, meeting record, or system report that supports this control.'}`;
    if (kind === 'summary') return `You have completed ${data.completed} of ${data.total} questions. Your current score is ${data.score}%.`;
    if (kind === 'prompt') return String(data.text ?? 'Tell me a little more and I will guide you.');
    return q;
  },
};

export const conversationAdapter: ConversationAdapter = noneAdapter;
