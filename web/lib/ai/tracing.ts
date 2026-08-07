import { createTraceId, startObservation } from '@langfuse/tracing';

type GenerationTrace = {
  sessionId: string;
  model: string;
  reasoningEffort: string;
  input: unknown;
  output: unknown;
  usage: unknown;
  latencyMs: number;
  error?: string;
};

export async function traceOpenAIGeneration(data: GenerationTrace) {
  if (!process.env.LANGFUSE_PUBLIC_KEY || !process.env.LANGFUSE_SECRET_KEY || !process.env.LANGFUSE_BASE_URL) return;
  try {
    const traceId = await createTraceId(data.sessionId);
    const generation = startObservation(
      'assessment.openai',
      {
        input: data.input,
        model: data.model,
        modelParameters: { reasoning_effort: data.reasoningEffort },
        metadata: { session_id: data.sessionId },
      },
      {
        asType: 'generation',
        parentSpanContext: {
          traceId,
          spanId: crypto.randomUUID().replace(/-/g, '').slice(0, 16),
          traceFlags: 1,
          isRemote: false,
        },
      },
    );
    generation.update({
      output: data.output,
      usageDetails: data.usage && typeof data.usage === 'object' ? data.usage as Record<string, number> : undefined,
      statusMessage: data.error,
      metadata: { session_id: data.sessionId, latency_ms: data.latencyMs },
    });
    generation.end();
  } catch {
    // Observability must never affect an assessment turn.
  }
}
