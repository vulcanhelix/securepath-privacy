-- ============================================================================
-- #95 — ONE monthly-snapshot writer + version-aware report consumers
-- ============================================================================
--
-- Two §9.5 snapshot writers existed with slightly different calculations:
--   * W1-09's sched_take_monthly_snapshot (20261106000004, patched for
--     retired rows in 20261106000013) — its own inline jsonb: overdue used
--     due_date, rag read the stored column only, kpi_actuals dropped KPIs
--     with no actual, taken_at never stamped;
--   * the canonical monthly_snapshot_figures + write_monthly_snapshot
--     (20261106000001, retired-row aware since 20261106000013) — the writer
--     report figures LOCK AGAINST, because create_monthly_report binds the
--     report row to the snapshot it writes.
-- A report built from a scheduler-written snapshot and one built from the
-- report path could disagree — the locked figure depended on who got there
-- first. Consolidated here: sched_take_monthly_snapshot keeps its signature
-- and idempotent-boolean contract but now delegates to write_monthly_snapshot,
-- so every call path stores exactly the canonical calculation.
--
-- The second half of #95: NFR-09 corrections (20261106000014) put a second
-- row on (programme_id, period) — UNIQUE(programme_id, period, version) +
-- at most one unissued row per period. Consumers that still assumed one
-- report per period are made version-aware:
--   * partner_console_rag — "report is late" is a PERIOD property: a period
--     is late only while NO version of it is issued. An open correction
--     draft of an already-issued period is not a late report.
--   * sched_daily_sweep's monthly_report_late event — same rule: emit only
--     for a period with no issued version (the payload names the open row).
--   * list_programmes — report_status/report_due_on pick the LATEST VERSION
--     of the latest period: the open correction is the live document, and
--     'draft' on an issued period correctly flags work in flight.
-- Deliberately untouched: monthly_snapshots stays strictly one row per
-- (programme, period) — a correction re-binds the SAME snapshot (§9.5), so
-- snapshot readers (annual_review_figures.months, report_document) need no
-- version logic; report builder RPCs were born version-aware.
-- ============================================================================

BEGIN;

-- ---------- 1. the single writer: scheduler delegates to W1-01 ----------
CREATE OR REPLACE FUNCTION public.sched_take_monthly_snapshot(
    p_programme uuid, p_period text, p_as_of date)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- idempotent contract preserved: an existing row is a no-op → false
  -- (the old body did ON CONFLICT (programme_id, period) DO NOTHING)
  IF EXISTS (SELECT 1 FROM public.monthly_snapshots s
              WHERE s.programme_id = p_programme AND s.period = p_period) THEN
    RETURN false;
  END IF;
  PERFORM public.write_monthly_snapshot(
      p_programme, (p_period || '-01')::date, p_as_of::timestamptz);
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  -- write_monthly_snapshot re-raises a duplicate period as raise_exception.
  -- If the row exists now, a concurrent write won the race — the append-only
  -- outcome is the same as the old ON CONFLICT no-op; anything else re-raises.
  IF EXISTS (SELECT 1 FROM public.monthly_snapshots s
              WHERE s.programme_id = p_programme AND s.period = p_period) THEN
    RETURN false;
  END IF;
  RAISE;
END $$;
COMMENT ON FUNCTION public.sched_take_monthly_snapshot(uuid, text, date) IS
  'W1-09 §9.5 → #95: same signature and idempotent-boolean contract, now a '
  'delegate of write_monthly_snapshot so scheduler- and report-path snapshots '
  'are byte-identical (single canonical calculation).';


-- ---------- 2. partner_console_rag — late is a period property ----------
CREATE OR REPLACE FUNCTION public.partner_console_rag(
    p_programme uuid, p_now timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT CASE
           WHEN EXISTS (SELECT 1 FROM public.programme_reports r
                         WHERE r.programme_id = p_programme
                           AND r.status <> 'issued'
                           AND coalesce(r.due_on,
                                        public.report_due_date(p_programme,
                                          (r.period || '-01')::date))
                               < p_now::date
                           -- #95: a period that HAS an issued version is not
                           -- late — an open correction draft is rework, not
                           -- an unissued report
                           AND NOT EXISTS (SELECT 1 FROM public.programme_reports x
                                            WHERE x.programme_id = r.programme_id
                                              AND x.period = r.period
                                              AND x.status = 'issued'))
             OR EXISTS (SELECT 1
                          FROM public.maintenance_task_instances mti
                          JOIN public.maintenance_task_templates t
                            ON t.id = mti.task_template_id
                         WHERE t.programme_id = p_programme
                           AND t.feeds ILIKE '%report%'
                           AND mti.due_date IS NOT NULL
                           AND mti.due_date < p_now::date
                           AND mti.status <> 'Complete')
           THEN 'Red'
           ELSE public.programme_rag(p_programme, p_now)
         END
$$;
COMMENT ON FUNCTION public.partner_console_rag(uuid, timestamptz) IS
  '§9.6: programme RAG forced Red when a monthly report is past due with no '
  'issued version (#95: an open correction of an issued period is not late), '
  'or a report-feeding maintenance task is overdue.';


-- ---------- 3. sched_daily_sweep — monthly_report_late is per-period ----------
-- Body identical to 20261106000004 except the monthly_report_late leg: a
-- period is late only while no version of it is issued.
CREATE OR REPLACE FUNCTION public.sched_daily_sweep(p_client uuid, p_local_date date)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_jur     text;
  v_overdue int;
  v_rag     int;
  v_events  jsonb := '{}'::jsonb;
  v_n       int;
BEGIN
  SELECT co.jurisdiction INTO v_jur FROM public.client_orgs co WHERE co.id = p_client;

  -- §9.3: days overdue = report date − planned close date, never below zero,
  -- blank once Closed. (report date = the client's local date at the due instant)
  WITH calc AS (
    SELECT r.id,
           CASE WHEN r.status = 'Closed' OR r.planned_close_date IS NULL THEN NULL
                ELSE greatest(p_local_date - r.planned_close_date, 0) END AS v
      FROM public.register_items r
      JOIN public.programmes p ON p.id = r.programme_id
     WHERE p.client_org_id = p_client)
  UPDATE public.register_items r
     SET days_overdue = c.v
    FROM calc c
   WHERE r.id = c.id AND r.days_overdue IS DISTINCT FROM c.v;
  GET DIAGNOSTICS v_overdue = ROW_COUNT;

  -- §9.2 ordered RAG rules (first match wins). Deterministic; when the W1-01
  -- rules engine lands its canonical function this call should delegate to it.
  WITH calc AS (
    SELECT a.id,
           CASE
             WHEN a.status = 'Complete' THEN 'Complete'
             WHEN a.status = 'Blocked'  THEN 'Red'
             WHEN a.due_date IS NOT NULL AND a.due_date < p_local_date
                  AND a.status <> 'Deferred'
               THEN CASE WHEN p_local_date - a.due_date > p.red_days_threshold
                         THEN 'Red' ELSE 'Amber' END
             WHEN a.status = 'At risk' THEN 'Amber'
             WHEN a.start_date IS NOT NULL AND a.start_date <= p_local_date
               THEN 'Green'
             ELSE 'Not due' END AS v
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
     WHERE p.client_org_id = p_client)
  UPDATE public.activities a
     SET rag = c.v
    FROM calc c
   WHERE a.id = c.id AND a.rag IS DISTINCT FROM c.v;
  GET DIAGNOSTICS v_rag = ROW_COUNT;

  -- §10 trigger events the daily job owns — emitted into the outbox for the
  -- W1-08 dispatcher; each deduped once-per-entity via the payload ref.
  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_due',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'due_date', a.due_date)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.due_date = p_local_date                      -- on the due date
       AND a.status NOT IN ('Complete','Deferred')
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_due'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_due', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_due_soon',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'due_date', a.due_date,
                              'business_days_before', 5)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.due_date = public.sched_add_business_days(p_local_date, 5, v_jur)
       AND a.status NOT IN ('Complete','Deferred')
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_due_soon'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_due_soon', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'activity_starting',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('activity_id', a.id, 'ref', a.ref, 'start_date', a.start_date)
      FROM public.activities a
      JOIN public.programmes p ON p.id = a.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND a.start_date BETWEEN p_local_date - 6 AND p_local_date  -- its start week
       AND a.status = 'Not started'
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'activity_starting'
                          AND ne.payload->>'activity_id' = a.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('activity_starting', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'maintenance_input_overdue',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('mti_id', m.id, 'code', t.code, 'due_date', m.due_date,
                              'period', m.period)
      FROM public.maintenance_task_instances m
      JOIN public.maintenance_task_templates t ON t.id = m.task_template_id
      JOIN public.programmes p ON p.id = t.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND m.due_date IS NOT NULL AND m.due_date < p_local_date
       AND m.status IN ('Pending','In progress')          -- "when overdue"
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'maintenance_input_overdue'
                          AND ne.payload->>'mti_id' = m.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('maintenance_input_overdue', v_n);

  WITH ins AS (
    INSERT INTO public.notification_events (kind, scope, payload)
    SELECT 'monthly_report_late',
           jsonb_build_object('practice_id', co.practice_id, 'client_org_id', co.id,
                              'programme_id', p.id),
           jsonb_build_object('report_id', r.id, 'period', r.period, 'due_on', r.due_on)
      FROM public.programme_reports r
      JOIN public.programmes p ON p.id = r.programme_id
      JOIN public.client_orgs co ON co.id = p.client_org_id
     WHERE co.id = p_client
       AND r.due_on IS NOT NULL AND r.due_on < p_local_date
       AND r.status <> 'issued'                           -- late = not issued by due_on
       -- #95: …and no version of the period ever issued — an open correction
       -- draft of an issued period is rework, not a late report
       AND NOT EXISTS (SELECT 1 FROM public.programme_reports x
                        WHERE x.programme_id = r.programme_id
                          AND x.period = r.period
                          AND x.status = 'issued')
       AND NOT EXISTS (SELECT 1 FROM public.notification_events ne
                        WHERE ne.kind = 'monthly_report_late'
                          AND ne.payload->>'report_id' = r.id::text)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  v_events := v_events || jsonb_build_object('monthly_report_late', v_n);

  -- owner stubs — parts of the §10 daily job that belong to other sessions:
  RAISE NOTICE 'W1-09 STUB daily-recalc-digest scope %: digest send is owned by W1-08 (notification dispatcher); phase/current-week recalc by W1-01 (rules engine)', p_client;

  RETURN jsonb_build_object(
      'local_date', p_local_date,
      'days_overdue_updated', v_overdue,
      'rag_updated', v_rag,
      'events_emitted', v_events,
      'stub', jsonb_build_object('digest','W1-08','phase_week_recalc','W1-01'));
END $$;
COMMENT ON FUNCTION public.sched_daily_sweep(uuid, date) IS
  'W1-09 daily 06:00 client-tz sweep: §9.3 days_overdue, §9.2 activity RAG and '
  'the §10 trigger events (deduped once-per-entity in the outbox). #95: '
  'monthly_report_late is a period property — a period with an issued '
  'version never emits, even while a correction draft is open. Digest send '
  '= W1-08, phase/week recalc = W1-01 — stubbed NOTICEs.';


-- ---------- 4. list_programmes — latest VERSION of the latest period ----------
-- Body identical to 20261106000013 except the two report subqueries, which
-- now break the per-period tie on version: the newest row wins, so an open
-- correction draft shows as the period's live report state.
CREATE OR REPLACE FUNCTION public.list_programmes(p_client_org_id uuid DEFAULT NULL)
RETURNS TABLE(
    programme_id            uuid,
    programme_name          text,
    client_org_id           uuid,
    client_name             text,
    framework               text,
    template_version_number int,
    status                  text,
    phase                   text,
    current_week            int,
    total_weeks             int,
    rag                     text,
    activities_total        bigint,
    activities_complete     bigint,
    activities_overdue      bigint,
    register_open           bigint,
    register_closed         bigint,
    evidence_pending        bigint,
    maintenance_due_month   bigint,
    maintenance_overdue_month bigint,
    report_status           text,
    report_due_on           date,
    programme_lead          uuid,
    assigned_consultants    text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.name, p.client_org_id, co.name,
         t.framework, v.number, p.status, p.phase,
         public.programme_week(p.id, CURRENT_DATE), p.total_weeks,
         public.partner_console_rag(p.id),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active AND a.status = 'Complete'),
         (SELECT count(*) FROM public.activities a WHERE a.programme_id = p.id
            AND a.active AND a.status <> 'Complete' AND a.due_date IS NOT NULL
            AND a.due_date < CURRENT_DATE),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.active AND r.status <> 'Closed'),
         (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p.id
            AND r.active AND r.status = 'Closed'),
         (SELECT count(*) FROM public.evidence_items e WHERE e.programme_id = p.id
            AND e.review_stage <> 'decided'),
         (SELECT count(*) FROM public.maintenance_task_instances mti
            JOIN public.maintenance_task_templates mt ON mt.id = mti.task_template_id
           WHERE mt.programme_id = p.id AND mti.status <> 'Complete'
             AND mti.due_date IS NOT NULL
             AND date_trunc('month', mti.due_date) = date_trunc('month', CURRENT_DATE)),
         (SELECT count(*) FROM public.maintenance_task_instances mti
            JOIN public.maintenance_task_templates mt ON mt.id = mti.task_template_id
           WHERE mt.programme_id = p.id AND mti.status <> 'Complete'
             AND mti.due_date IS NOT NULL AND mti.due_date < CURRENT_DATE),
         -- #95: latest period, latest version — an open correction draft is
         -- the period's live report state (issued + open correction → 'draft')
         (SELECT r.status FROM public.programme_reports r
           WHERE r.programme_id = p.id
           ORDER BY r.period DESC, r.version DESC LIMIT 1),
         (SELECT coalesce(r.due_on, public.report_due_date(p.id, (r.period || '-01')::date))
            FROM public.programme_reports r
           WHERE r.programme_id = p.id
           ORDER BY r.period DESC, r.version DESC LIMIT 1),
         p.programme_lead,
         (SELECT array_agg(u.full_name)
            FROM public.role_assignments ra
            JOIN public.users u ON u.id = ra.user_id
           WHERE ra.level = 'partner' AND ra.role = 'partner_consultant'
             AND ra.start_date <= CURRENT_DATE
             AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
             AND ((ra.scope_type = 'client' AND ra.scope_id = co.id)
               OR (ra.scope_type = 'partner' AND ra.scope_id = co.practice_id)
               OR (ra.scope_type = 'programme' AND ra.scope_id = p.id)))
    FROM public.programmes p
    JOIN public.client_orgs co ON co.id = p.client_org_id
    LEFT JOIN public.programme_template_versions v ON v.id = p.template_version_id
    LEFT JOIN public.programme_templates t ON t.id = v.template_id
   WHERE p.id IN (SELECT public.allowed_programmes())
     AND (p_client_org_id IS NULL OR p.client_org_id = p_client_org_id)
   ORDER BY co.name, p.name
$$;
COMMENT ON FUNCTION public.list_programmes(uuid) IS
  'W1-05 FR-PCN-01: partner-console programme rows — client, framework, '
  'phase, week, console RAG (forced Red on late report/overdue report-fed '
  'task), register/activity/evidence/maintenance rollups, latest report '
  'status + due date (#95: latest VERSION of the latest period — an open '
  'correction is the live row), lead and assigned consultants.';


COMMIT;
