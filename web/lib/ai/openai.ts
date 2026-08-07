import type { CanonicalAnswer, EngineQuestion, EngineTurn } from './engine';

export type ModelRequest = {
  task: 'classify' | 'explain' | 'question' | 'findings';
  sessionId: string;
  question: EngineQuestion;
  userInput: string;
  turns: EngineTurn[];
};

export type ModelResult = {
  response?: CanonicalAnswer;
  message: string;
  draft?: string;
  model: string;
  status: string;
};

const endpoint = 'https://api.openai.com/v1/responses';
const defaultModel = 'gpt-5.6-luna';
const defaultReasoningEffort = 'max';
const defaultTimeoutMs = 30_000;

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

function parseResult(text: string, task: ModelRequest['task'], model: string, status: string): ModelResult | null {
  try {
    const parsed = JSON.parse(text) as { response?: unknown; message?: unknown; draft?: unknown };
    if (typeof parsed.message !== 'string' || !parsed.message.trim()) return null;
    if (task === 'findings') {
      if (typeof parsed.draft !== 'string' || !parsed.draft.trim()) return null;
      return { draft: parsed.draft.trim(), message: parsed.message.trim(), model, status };
    }
    if (task === 'classify') {
      const responses: CanonicalAnswer[] = ['fully_compliant', 'partial', 'non_compliant', 'na'];
      if (!responses.includes(parsed.response as CanonicalAnswer)) return null;
      return { response: parsed.response as CanonicalAnswer, message: parsed.message.trim(), model, status };
    }
    return { message: parsed.message.trim(), model, status };
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
  const taskInstruction = request.task === 'classify'
    ? 'Classify the user answer only as fully_compliant, partial, non_compliant, or na. Do not write or imply that you wrote an assessment response. Your message must state the proposed classification and ask the user to confirm it explicitly with "confirm <classification>".'
    : request.task === 'explain'
      ? 'Explain the current question plainly and helpfully. Use only the supplied grounding. Do not classify or write an assessment response.'
      : request.task === 'question'
        ? 'Rewrite the current question as a warm, concise conversational prompt. Preserve its meaning. Do not add requirements or regulatory claims.'
        : 'Draft a concise findings entry from the user answer, preserving uncertainty and facts without inventing details. Do not classify or write an assessment response.';
  const schema = request.task === 'classify'
    ? {
        type: 'object',
        additionalProperties: false,
        properties: {
          response: { type: 'string', enum: ['fully_compliant', 'partial', 'non_compliant', 'na'] },
          message: { type: 'string' },
        },
        required: ['response', 'message'],
      }
    : request.task === 'findings'
      ? {
          type: 'object',
          additionalProperties: false,
          properties: {
            draft: { type: 'string' },
            message: { type: 'string' },
          },
          required: ['draft', 'message'],
        }
      : {
          type: 'object',
          additionalProperties: false,
          properties: { message: { type: 'string' } },
          required: ['message'],
        };
  return {
    input: [
    {
      role: 'system',
      content: `You assist with one compliance assessment question. ${taskInstruction} Return JSON matching the requested schema. Use only the current question and supplied grounding. Do not invent statute sections, legal citations, case law, or regulatory claims. Do not mention files or evidence contents. Grounding:\n${grounding || 'No additional grounding was supplied.'}`,
    },
    {
      role: 'user',
      content: `Current question: ${request.question.question}\nUser answer: ${request.userInput}\nRecent conversation:\n${transcript || '(none)'}`,
    },
    ],
    text: {
      format: {
        type: 'json_schema',
        name: request.task === 'classify' ? 'assessment_classification' : `assessment_${request.task}`,
        strict: true,
        schema,
      },
    },
  };
}

export const openAIAdapter = {
  async generate(request: ModelRequest): Promise<ModelResult | null> {
    const config = settings();
    const forcedNone = provider() === 'none' || provider() === 'deterministic';
    if (forcedNone) return null;
    if (!config.key) return null;
    const requestParts = inputFor(request);
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
          ...requestParts,
        }),
        signal: controller.signal,
      });
      body = await response.json().catch(() => null);
      if (!response.ok) throw new Error(`OpenAI API error (${response.status})`);
      const text = textFromResponse(body);
      if (!text) throw new Error('OpenAI response contained no output text');
      result = parseResult(text, request.task, typeof (body as { model?: unknown })?.model === 'string' ? (body as { model: string }).model : config.model, typeof (body as { status?: unknown })?.status === 'string' ? (body as { status: string }).status : 'unknown');
      if (!result) throw new Error('OpenAI response did not match the classification schema');
      return result;
    } catch (caught) {
      error = caught instanceof Error ? caught.message : 'OpenAI request failed';
      return null;
    } finally {
      clearTimeout(timeout);
      const usage = body && typeof body === 'object' && (body as { usage?: unknown }).usage;
      console.info('[assessment-ai]', JSON.stringify({
        session_id: request.sessionId,
        model: result?.model ?? config.model,
        status: result?.status ?? 'error',
        latency_ms: Date.now() - started,
        usage,
        error,
      }));
    }
  },
};
