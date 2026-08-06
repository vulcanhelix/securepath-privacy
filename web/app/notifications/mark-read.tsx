'use client';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

export default function MarkRead() {
  const router = useRouter();
  return (
    <button
      style={{ background: 'var(--muted)' }}
      onClick={async () => {
        await browserClient().from('notifications').update({ read: true }).eq('read', false);
        router.refresh();
      }}
    >
      Mark all read
    </button>
  );
}
