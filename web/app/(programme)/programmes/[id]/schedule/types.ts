// W2-05 — shared row types for the schedule screen (spec §6.2). These mirror
// the engine tables verbatim; all date/week/RAG fields are engine-written
// CALC columns — the UI renders them, it never recomputes them.

export interface ScheduleActivity {
  id: string;
  ref: string;
  text: string;
  workstream_id: string | null;
  phase: string | null; // CALC: phase covering end_week (§9.1)
  start_week: number;
  end_week: number;
  milestone: boolean;
  evidence_required: boolean;
  status: 'Not started' | 'In progress' | 'At risk' | 'Blocked' | 'Deferred' | 'Complete' | string;
  pct_complete: number;
  actual_completion: string | null;
  flag: boolean;
  comments: string | null;
  recovery_date: string | null;
  dependency_override_reason: string | null;
  rescheduled_date: string | null;
  start_date: string | null; // CALC
  due_date: string | null;   // CALC: Friday of end_week
  month: number | null;      // CALC: programme month
  rag: 'Not due' | 'Green' | 'Amber' | 'Red' | 'Complete' | null; // CALC §9.2
  leads: string[];
}

export interface SchedulePhase {
  id: string;
  number: number;
  name: string;
  start_week: number;
  end_week: number;
}

export interface ScheduleWorkstream {
  id: string;
  name: string;
  accountable_lead: string | null;
}

export interface ScheduleDep {
  activity_id: string;
  depends_on_activity_id: string;
}

export interface ScheduleEvidenceCount {
  activityId: string;
  total: number;
  decided: number;
}

export interface RegisterLink {
  activityId: string;
  registerItemId: string;
  ref: string | null;
  status: string | null;
}
