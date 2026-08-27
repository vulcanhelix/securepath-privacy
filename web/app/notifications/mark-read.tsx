'use client';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import { Button } from '@/components/ui/Button';

export default function MarkRead() {
  const router = useRouter();
  return (
    <Button
      variant="secondary"
      size="sm"
      onClick={async () => {
        await browserClient().from('notifications').update({ read: true }).eq('read', false);
        router.refresh();
      }}
    >
      Mark all read
    </Button>
  );
}
