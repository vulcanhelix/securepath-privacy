'use client';
import { usePathname, useRouter } from 'next/navigation';
import { WeekPicker } from '@/components/ui/WeekPicker';

// W2-07 — the page owns the selected week through ?week= (WeekPicker is
// controlled); moving weeks is a navigation, so the server re-reads the log.
export function WeeklyWeekPicker({
  week,
  totalWeeks,
  currentWeek,
}: {
  week: number;
  totalWeeks: number;
  currentWeek: number | null;
}) {
  const router = useRouter();
  const pathname = usePathname();
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
      <WeekPicker
        week={week}
        totalWeeks={totalWeeks}
        onChange={(w) => router.push(`${pathname}?week=${w}`)}
      />
      {currentWeek && currentWeek !== week ? (
        <button
          type="button"
          className="sp-btn sp-btn--ghost sp-btn--sm"
          onClick={() => router.push(`${pathname}?week=${currentWeek}`)}
        >
          <span>This week</span>
        </button>
      ) : null}
    </span>
  );
}
