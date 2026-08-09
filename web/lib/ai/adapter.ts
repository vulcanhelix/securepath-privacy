import { openAIAdapter, type ModelRequest, type ModelResult } from './openai';

export interface ConversationAdapter {
  render(kind: 'question' | 'explainer' | 'example' | 'prompt' | 'summary', data: Record<string, unknown>): string;
  generate(request: ModelRequest): Promise<ModelResult | null>;
}

export const noneAdapter: ConversationAdapter = {
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
  async generate() {
    return null;
  },
};

export const conversationAdapter: ConversationAdapter = {
  ...noneAdapter,
  generate: openAIAdapter.generate,
};
