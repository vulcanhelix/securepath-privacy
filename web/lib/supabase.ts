import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

const URL_ = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export async function serverClient() {
  const store = await cookies();
  return createServerClient(URL_, ANON, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (all) => {
        try {
          all.forEach(({ name, value, options }) => store.set(name, value, options));
        } catch {} // server components can't set cookies; middleware handles refresh
      },
    },
  });
}
