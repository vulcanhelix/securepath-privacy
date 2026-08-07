import type { CanonicalAnswer, EngineQuestion, EngineTurn } from './engine';
import { traceOpenAIGeneration } from './tracing';

export type ModelRequest = {
  task: 'classify';
  sessionId: string;
  question: EngineQuestion;
  userInput: string;
  turns: EngineTurn[];
};

export type ModelResult = {
  response: CanonicalAnswer;
  message: string;
  model: string;
  status: string;
};

const endpoint = 'https://api.openai.com/v1/responses';
const defaultModel = 'gpt-5.6-luna';
const defaultReasoningEffort = 'max';
const defaultTimeoutMs = 15_000;

function provider() {
  return (process.env.AI_PROVIDER ?? 'auto').trim().toLowerCase();
}

function settings() {
  return {
    key: process.env.OPENAI_API_KEY,
    model: process.env.OPENAI_MODEL || defaultModel,
    reasoningEffort: process.env.OPENAI_REASONING_EFFORT || defaultReasoningEffort,
    timeoutMs: Number(process.env.OPENAI_TIMEOUT_MS || defaultTimeoutMs),
  };
}

function textFromResponse(body: unknown): string | null {
  if (!body || typeof body !== 'object') return null;
  const output = (body as { output?: unknown }).output;
  if (!Array.isArray(output)) return null;
  const texts = output.flatMap(item => {
    if (!item || typeof item !== 'object') return [];
    const content = (item as { content?: unknown }).content;
    if (!Array.isArray(content)) return [];
    return content.flatMap(part => {
      if (!part || typeof part !== 'object') return [];
      const text = (part as { text?: unknown }).text;
      return typeof text === 'string' ? [text] : [];
    });
  });
  return texts.join('').trim() || null;
}

function parseResult(text: string, model: string, status: string): ModelResult | null {
  try {
    const parsed = JSON.parse(text) as { response?: unknown; message?: unknown };
    const responses: CanonicalAnswer[] = ['fully_compliant', 'partial', 'non_compliant', 'na'];
    if (!responses.includes(parsed.response as CanonicalAnswer) || typeof parsed.message !== 'string') return null;
    return { response: parsed.response as CanonicalAnswer, message: parsed.message.trim(), model, status };
  } catch {
    return null;
  }
}

function inputFor(request: ModelRequest) {
  const grounding = [
    request.question.why_matters ? `Why it matters: ${request.question.why_matters}` : '',
    request.question.regulatory_ref ? `Regulatory reference supplied by the assessment: ${request.question.regulatory_ref}` : '',
    request.question.remediation ? `Remediation supplied by the assessment: ${request.question.remediation}` : '',
  ].filter(Boolean).join('\n');
  const transcript = request.turns
    .filter(turn => turn.kind !== 'upload')
    .slice(-8)
    .map(turn => `${turn.role}: ${turn.content}`)
    .join('\n');
  return [
    {
      role: 'system',
      content: `You assist with one compliance assessment question. Classify the user's answer only as fully_compliant, partial, non_compliant, or na. Do not write or imply that you wrote an assessment response. Return JSON matching the requested schema. Your message must state the proposed classification and ask the user to confirm it explicitly with "confirm <classification>". Use only the current question and the supplied grounding. Do not invent statute sections, legal citations, case law, or regulatory claims. Do not mention files or evidence contents. Grounding:\n${grounding || 'No additional grounding was supplied.'}`,
    },
    {
      role: 'user',
      content: `Current question: ${request.question.question}\nUser answer: ${request.userInput}\nRecent conversation:\n${transcript || '(none)'}`,
    },
  ];
}

export const openAIAdapter = {
  async generate(request: ModelRequest): Promise<ModelResult | null> {
    const config = settings();
    const forcedNone = provider() === 'none' || provider() === 'deterministic';
    const forcedOpenAI = provider() === 'openai';
    if (forcedNone || (!config.key && !forcedOpenAI)) return null;
    if (!config.key) return null;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), Number.isFinite(config.timeoutMs) && config.timeoutMs > 0 ? config.timeoutMs : defaultTimeoutMs);
    const started = Date.now();
    let body: unknown;
    let result: ModelResult | null = null;
    let error: string | undefined;
    try {
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { authorization: `Bearer ${config.key}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          model: config.model,
          reasoning: { effort: config.reasoningEffort },
          input: inputFor(request),
          text: {
            format: {
              type: 'json_schema',
              name: 'assessment_classification',
              strict: true,
              schema: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  response: { type: 'string', enum: ['fully_compliant', 'partial', 'non_compliant', 'na'] },
                  message: { type: 'string' },
                },
                required: ['response', 'message'],
              },
            },
          },
        }),
        signal: controller.signal,
      });
      body = await response.json().catch(() => null);
      if (!response.ok) throw new Error(`OpenAI API error (${response.status})`);
      const text = textFromResponse(body);
      if (!text) throw new Error('OpenAI response contained no output text');
      result = parseResult(text, typeof (body as { model?: unknown })?.model === 'string' ? (body as { model: string }).model : config.model, typeof (body as { status?: unknown })?.status === 'string' ? (body as { status: string }).status : 'unknown');
      if (!result) throw new Error('OpenAI response did not match the classification schema');
      return result;
    } catch (caught) {
      error = caught instanceof Error ? caught.message : 'OpenAI request failed';
      return null;
    } finally {
      clearTimeout(timeout);
      void traceOpenAIGeneration({
        sessionId: request.sessionId,
        model: config.model,
        reasoningEffort: config.reasoningEffort,
        input: inputFor(request),
        output: result,
        usage: body && typeof body === 'object' && (body as { usage?: unknown }).usage,
        latencyMs: Date.now() - started,
        error,
      });
    }
  },
};
