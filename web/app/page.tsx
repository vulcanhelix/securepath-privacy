import Link from 'next/link';
import { redirect } from 'next/navigation';
import { serverClient } from '@/lib/supabase';

export default async function Home() {
  const supabase = await serverClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (user) redirect('/dashboard');
  return (
    <div className="card" style={{ textAlign: 'center', padding: '3rem' }}>
      <h1>POPIA &amp; GDPR compliance, run by your MSP</h1>
      <p className="muted">Multi-tenant privacy compliance platform for MSP resellers and their clients.</p>
      <p><Link href="/signup"><button>Create your practice account</button></Link></p>
      <p className="muted">Already registered? <Link href="/login">Sign in</Link></p>
    </div>
  );
}
