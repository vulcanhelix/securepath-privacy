import Link from 'next/link';
import { notFound } from 'next/navigation';
import { programmeContext } from '@/lib/programme-context';
import { visibleSlots } from '@/lib/nav';
import { ProgrammeNav } from '@/components/programme/ProgrammeNav';
import { RagBadge } from '@/components/ui/RagBadge';
import { StatusPill } from '@/components/ui/StatusPill';

export const dynamic = 'force-dynamic';

// W2-00 — programme-scoped chrome. Resolves the full context once
// (programme + client + partner brand + role) and renders the role-filtered
// module tab strip. Every W2 programme screen is a page.tsx under this
// layout — mount your slot in lib/nav.ts and go.

export default async function ProgrammeLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const ctx = await programmeContext(id);
  if (!ctx) notFound(); // absent or RLS-invisible — same answer either way

  const slots = visibleSlots(ctx.role, 'programme', ctx.client.id);

  return (
    <>
      <div className="sp-ctxbar">
        <div className="sp-ctx-crumb">
          <Link href="/programmes" className="sp-ctx-client">
            {ctx.client.name}
          </Link>
          <span className="sp-ctx-sep">/</span>
          <span className="sp-ctx-name">{ctx.programme.name}</span>
          <StatusPill status={ctx.programme.status} />
          {ctx.programme.phase ? <span className="muted">{ctx.programme.phase}</span> : null}
          <RagBadge rag={ctx.programme.programme_rag} />
        </div>
      </div>
      <ProgrammeNav slots={slots} base={`/programmes/${id}`} />
      {children}
    </>
  );
}
