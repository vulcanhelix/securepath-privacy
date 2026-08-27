import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';
import { Button } from '@/components/ui/Button';

export default async function Home() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (user) redirect('/dashboard');
  return (
    <div style={{ textAlign: 'center', paddingTop: 48 }}>
      <h1 style={{ fontSize: 'var(--fs-h1)', letterSpacing: 'var(--ls-tight)' }}>
        POPIA &amp; GDPR compliance, run by your MSP
      </h1>
      <p className="muted" style={{ fontSize: 'var(--fs-lead)', letterSpacing: 'var(--ls-snug)' }}>
        Multi-tenant privacy compliance platform for MSP resellers and their clients.
      </p>
      <p style={{ marginTop: 32 }}>
        <Link href="/signup">
          <Button cta>Create your practice account</Button>
        </Link>
      </p>
      <p className="muted">
        Already registered? <Link href="/login" style={{ color: 'var(--text)' }}>Sign in</Link>
      </p>
    </div>
  );
}
