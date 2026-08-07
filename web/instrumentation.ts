import { LangfuseSpanProcessor } from '@langfuse/otel';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';

let provider: NodeTracerProvider | undefined;

export async function register() {
  if (process.env.NEXT_RUNTIME === 'edge') return;
  if (!process.env.LANGFUSE_PUBLIC_KEY || !process.env.LANGFUSE_SECRET_KEY || !process.env.LANGFUSE_BASE_URL || provider) return;
  const processor = new LangfuseSpanProcessor({
    publicKey: process.env.LANGFUSE_PUBLIC_KEY,
    secretKey: process.env.LANGFUSE_SECRET_KEY,
    baseUrl: process.env.LANGFUSE_BASE_URL,
    environment: process.env.LANGFUSE_TRACING_ENVIRONMENT || 'production',
    exportMode: 'immediate',
  });
  provider = new NodeTracerProvider({ spanProcessors: [processor] });
  provider.register();
}
