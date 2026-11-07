-- 20261106000022_w2_13_exec_myactions.sql — W2-13 (GitHub #38): the two
-- cross-RLS reads behind the executive view (spec §8.14 FR-EXE-01) and the
-- 390px "my actions" surface (§8.15 FR-MOB-01). No tables, no writes — two
-- STABLE SECURITY DEFINER read RPCs, both following the W4-D2
-- programme_context() precedent (20261106000018):
--
--   * DEFINER because programme/workstream-scope callers pass
--     allowed_programmes() but cannot read every T2 row the rollup needs
--     (client_orgs-adjacent figures are fine; the point is one uniform,
--     guarded read surface).
--   * The guard is IN THE BODY — a definer function bypasses RLS, so
--     allowed_programmes() is checked explicitly. auth.uid() NULL = the
--     service/migration path and runs free (W0-02 convention).
--   * Server-side figures only (FR-EXE-01 / the §9 rules): week, phase,
--     RAG, overdue and acceptance rate are computed by the engine
--     functions — the app formats, it does not recompute.
--
-- programme_executive_rollup → jsonb:
--   { programme_id, as_of, week, total_weeks, phase, status, rag,
--     register  {open_high, open_medium, open_low, closed, overdue},
--     activities{total, complete, overdue},
--     milestones[{id, ref, text, status, end_week, due_date}]          ≤5, open
--     raid      {open, due_for_review},
--     decisions [{outcome, decided_on, minute_ref}]                    ≤5, latest
--     evidence  {awaiting_verification, awaiting_acceptance,
--                accepted, returned, acceptance_rate},
--     maintenance{period, done, open, overdue_all},
--     latest_report{id, period, reference, overall_rag, issued_on} | null }
--
-- my_actions → jsonb:
--   { programme_id, as_of, week,
--     activities[{id, ref, text, status, rag, end_week, due_date,
--                 overdue, due_this_week}],          caller ∈ leads
--     evidence{can_verify, is_ao_or_alternate,
--              verify[{…}], accept[{…}]},            via list_pending_reviews
--     maintenance[{id, code, task, period, due_date, task_window, status,
--                  overdue}],                        assignee = caller
--     can_complete_checklists, checklists[{checklist_id, kind, period,
--                  item_ref, label, evidence_required}] }

-- ---------- programme_executive_rollup — §8.14 FR-EXE-01 ----------
CREATE OR REPLACE FUNCTION public.programme_executive_rollup(p_programme uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog   public.programmes%ROWTYPE;
  v_week   int;
  v_period text := to_char(CURRENT_DATE, 'YYYY-MM');
BEGIN
  IF auth.uid() IS NOT NULL
     AND p_programme NOT IN (SELECT public.allowed_programmes()) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_week := public.programme_week(p_programme, CURRENT_DATE);

  RETURN jsonb_build_object(
    'programme_id', p_programme,
    'as_of',        CURRENT_DATE,
    'week',         v_week,
    'total_weeks',  v_prog.total_weeks,
    'phase',        public.programme_phase_at(p_programme, CURRENT_DATE),
    'status',       v_prog.status,
    'rag',          public.programme_rag(p_programme),

    -- open findings by severity + §9.3 overdue (CALC column; the week→date
    -- fallback matches the engine formula when the column lags)
    'register', (SELECT jsonb_build_object(
        'open_high',   count(*) FILTER (WHERE r.status <> 'Closed' AND r.priority = 'High'),
        'open_medium', count(*) FILTER (WHERE r.status <> 'Closed' AND r.priority = 'Medium'),
        'open_low',    count(*) FILTER (WHERE r.status <> 'Closed' AND r.priority = 'Low'),
        'closed',      count(*) FILTER (WHERE r.status = 'Closed'),
        'overdue',     count(*) FILTER (WHERE r.status <> 'Closed'
          AND coalesce(r.planned_close_date,
                       v_prog.start_date + (r.planned_close_week - 1) * 7 + 4)
              < CURRENT_DATE))
       FROM public.register_items r
      WHERE r.programme_id = p_programme AND r.active),

    'activities', (SELECT jsonb_build_object(
        'total',    count(*),
        'complete', count(*) FILTER (WHERE a.status = 'Complete'),
        'overdue',  count(*) FILTER (WHERE a.status <> 'Complete'
          AND CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                   THEN a.rescheduled_date
                   ELSE coalesce(a.due_date,
                                 v_prog.start_date + (a.end_week - 1) * 7 + 4)
              END < CURRENT_DATE))
       FROM public.activities a
      WHERE a.programme_id = p_programme AND a.active),

    -- FR-EXE-01 milestones: the next open milestones, engine-dated
    'milestones', coalesce((SELECT jsonb_agg(row_to_json(x) ORDER BY x.due_date, x.ref)
       FROM (SELECT a.id, a.ref, a.text, a.status, a.end_week,
                    CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                         THEN a.rescheduled_date
                         ELSE coalesce(a.due_date,
                                       v_prog.start_date + (a.end_week - 1) * 7 + 4)
                    END AS due_date
               FROM public.activities a
              WHERE a.programme_id = p_programme AND a.active
                AND a.milestone AND a.status <> 'Complete'
              ORDER BY 6, a.ref LIMIT 5) x), '[]'::jsonb),

    -- open decisions = open RAID items still needing a review/decision;
    -- the decisions ledger supplies the latest recorded ones
    'raid', (SELECT jsonb_build_object(
        'open',           count(*),
        'due_for_review', count(*) FILTER (WHERE r.review_by IS NOT NULL
                                            AND r.review_by <= CURRENT_DATE))
       FROM public.raid_items r
      WHERE r.programme_id = p_programme AND r.status <> 'Closed'),

    'decisions', coalesce((SELECT jsonb_agg(row_to_json(x) ORDER BY x.decided_on DESC)
       FROM (SELECT d.outcome, d.decided_on, d.minute_ref, r.description
               FROM public.decisions d
               JOIN public.raid_items r ON r.id = d.raid_item_id
              WHERE r.programme_id = p_programme
              ORDER BY d.decided_on DESC, d.created_at DESC LIMIT 5) x), '[]'::jsonb),

    -- acceptance rate = accepted / (accepted + returned) over the review
    -- ledger (accept-stage decisions); NULL until anything is decided
    'evidence', (SELECT jsonb_build_object(
        'awaiting_verification', count(*) FILTER (WHERE e.review_stage = 'verification'),
        'awaiting_acceptance',   count(*) FILTER (WHERE e.review_stage = 'acceptance'),
        'accepted',  (SELECT count(*) FROM public.evidence_reviews er
                       JOIN public.evidence_items ei ON ei.id = er.evidence_item_id
                      WHERE ei.programme_id = p_programme
                        AND er.stage = 'accept' AND er.decision = 'accepted'),
        'returned',  (SELECT count(*) FROM public.evidence_reviews er
                       JOIN public.evidence_items ei ON ei.id = er.evidence_item_id
                      WHERE ei.programme_id = p_programme
                        AND er.decision = 'returned'),
        'acceptance_rate',
          (SELECT CASE WHEN count(*) FILTER (WHERE er.decision = 'accepted')
                        + count(*) FILTER (WHERE er.decision = 'returned'
                                           AND er.stage = 'accept') = 0 THEN NULL
                       ELSE round(
                         count(*) FILTER (WHERE er.decision = 'accepted')::numeric
                         / (count(*) FILTER (WHERE er.decision = 'accepted')
                          + count(*) FILTER (WHERE er.decision = 'returned'
                                             AND er.stage = 'accept')), 2)
                  END
             FROM public.evidence_reviews er
             JOIN public.evidence_items ei ON ei.id = er.evidence_item_id
            WHERE ei.programme_id = p_programme AND er.stage = 'accept'))
       FROM public.evidence_items e
      WHERE e.programme_id = p_programme),

    -- maintenance posture: current-period instances + every overdue open one
    'maintenance', (SELECT jsonb_build_object(
        'period',      v_period,
        'done',        count(*) FILTER (WHERE mti.period = v_period AND mti.status = 'Complete'),
        'open',        count(*) FILTER (WHERE mti.period = v_period AND mti.status <> 'Complete'),
        'overdue_all', count(*) FILTER (WHERE mti.status <> 'Complete'
                                         AND mti.due_date IS NOT NULL
                                         AND mti.due_date < CURRENT_DATE))
       FROM public.maintenance_task_instances mti
       JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
      WHERE t.programme_id = p_programme),

    -- FR-EXE-01 latest signed/issued report — immutable once issued (§9.5)
    'latest_report', (SELECT jsonb_build_object(
        'id', rp.id, 'period', rp.period, 'reference', rp.reference,
        'overall_rag', rp.overall_rag, 'issued_on', rp.issued_on)
       FROM public.programme_reports rp
      WHERE rp.programme_id = p_programme AND rp.status = 'issued'
      ORDER BY rp.period DESC LIMIT 1)
  );
END $$;
COMMENT ON FUNCTION public.programme_executive_rollup(uuid) IS
  'W2-13 FR-EXE-01: the executive-view figures — week/phase/RAG, findings by '
  'severity, milestones, open RAID/decisions, evidence acceptance rate, '
  'maintenance posture, latest issued report. DEFINER, guarded in-body by '
  'allowed_programmes() (programme_context precedent): scoped callers get '
  'the same numbers as tenant-wide ones, nothing extra leaks.';

-- ---------- my_actions — §8.15 FR-MOB-01 "what I must do" ----------
CREATE OR REPLACE FUNCTION public.my_actions(p_programme uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog    public.programmes%ROWTYPE;
  v_uid     uuid := auth.uid();
  v_week    int;
  v_pending jsonb;
  v_can_ck  boolean;
BEGIN
  IF v_uid IS NOT NULL
     AND p_programme NOT IN (SELECT public.allowed_programmes()) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_week := public.programme_week(p_programme, CURRENT_DATE);

  -- the W1-02 review queues: verify = PL/consultant checklist, accept = the
  -- AO/alternate decision; flags and not-own-upload filtering resolved there
  v_pending := public.list_pending_reviews(p_programme);
  v_can_ck  := public.can_run_cadence(p_programme);

  RETURN jsonb_build_object(
    'programme_id', p_programme,
    'as_of',        CURRENT_DATE,
    'week',         v_week,

    -- activities the caller leads: overdue first, then due this week (§9.1)
    'activities', coalesce((SELECT jsonb_agg(row_to_json(x) ORDER BY x.due_date, x.ref)
       FROM (SELECT a.id, a.ref, a.text, a.status, a.rag, a.end_week,
                    CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                         THEN a.rescheduled_date
                         ELSE coalesce(a.due_date,
                                       v_prog.start_date + (a.end_week - 1) * 7 + 4)
                    END AS due_date,
                    (CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                          THEN a.rescheduled_date
                          ELSE coalesce(a.due_date,
                                        v_prog.start_date + (a.end_week - 1) * 7 + 4)
                     END) < CURRENT_DATE AS overdue,
                    (a.end_week = v_week) AS due_this_week
               FROM public.activities a
              WHERE a.programme_id = p_programme AND a.active
                AND v_uid = ANY(a.leads)
                AND a.status <> 'Complete'
                AND (a.end_week <= coalesce(v_week, 0)
                     OR (CASE WHEN a.status = 'Deferred' AND a.rescheduled_date IS NOT NULL
                              THEN a.rescheduled_date
                              ELSE coalesce(a.due_date,
                                            v_prog.start_date + (a.end_week - 1) * 7 + 4)
                         END) < CURRENT_DATE)
              ORDER BY 7, a.ref LIMIT 50) x), '[]'::jsonb),

    -- evidence awaiting the caller's own step (never their own uploads —
    -- list_pending_reviews already applies that and the role flags)
    'evidence', jsonb_build_object(
      'can_verify',           coalesce(v_pending ->> 'caller_can_verify', 'false')::boolean,
      'is_ao_or_alternate',   coalesce(v_pending ->> 'caller_is_ao_or_alternate', 'false')::boolean,
      'verify', CASE WHEN coalesce(v_pending ->> 'caller_can_verify', 'false')::boolean
                     THEN coalesce(v_pending -> 'verify', '[]'::jsonb) ELSE '[]'::jsonb END,
      'accept', CASE WHEN coalesce(v_pending ->> 'caller_is_ao_or_alternate', 'false')::boolean
                     THEN coalesce(v_pending -> 'accept', '[]'::jsonb) ELSE '[]'::jsonb END),

    -- maintenance instances assigned to the caller and still open
    'maintenance', coalesce((SELECT jsonb_agg(row_to_json(x) ORDER BY x.due_date NULLS LAST)
       FROM (SELECT mti.id, t.code, t.task, mti.period, mti.due_date,
                    mti.task_window, mti.status,
                    (mti.due_date IS NOT NULL AND mti.due_date < CURRENT_DATE) AS overdue
               FROM public.maintenance_task_instances mti
               JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
              WHERE t.programme_id = p_programme
                AND mti.assignee = v_uid
                AND mti.status <> 'Complete'
              ORDER BY mti.due_date NULLS LAST LIMIT 50) x), '[]'::jsonb),

    -- checklist items the caller may complete (FR-QTR role set = cadence)
    'can_complete_checklists', v_can_ck,
    'checklists', CASE WHEN v_can_ck THEN coalesce((SELECT jsonb_agg(row_to_json(x))
         FROM (SELECT c.id AS checklist_id, c.kind, c.period,
                      it.item ->> 'ref'   AS item_ref,
                      it.item ->> 'label' AS label,
                      coalesce((it.item ->> 'evidence_required')::boolean, false)
                                          AS evidence_required
                 FROM public.checklist_instances c,
                      LATERAL jsonb_array_elements(coalesce(c.items, '[]'::jsonb)) it(item)
                WHERE c.programme_id = p_programme
                  AND it.item ->> 'ref' IS NOT NULL
                  AND NOT coalesce((it.item ->> 'done')::boolean, false)
                ORDER BY c.generated_on DESC, it.item ->> 'ref' LIMIT 25) x), '[]'::jsonb)
                  ELSE '[]'::jsonb END
  );
END $$;
COMMENT ON FUNCTION public.my_actions(uuid) IS
  'W2-13 FR-MOB-01: the caller''s open actions on one programme — activities '
  'they lead that are overdue or due this week, evidence waiting on their '
  'verification (PL/consultant) or acceptance (AO/alternate — flags from '
  'list_pending_reviews), maintenance instances assigned to them, and '
  'completable checklist items (can_run_cadence). DEFINER + in-body '
  'allowed_programmes() guard; returns NULL outside scope.';

REVOKE EXECUTE ON FUNCTION
  public.programme_executive_rollup(uuid),
  public.my_actions(uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.programme_executive_rollup(uuid),
  public.my_actions(uuid)
TO authenticated;
