-- ============================================================================
-- W1-03 — CADENCE ENGINE: monthly maintenance generation (FR-MNT-01..08,10),
-- quarterly/annual checklist generation (FR-QTR-01/02), provider input
-- requests (FR-MNT-04), and the FR-MNT-07 report-review gate
-- (GitHub #17 · spec SP-SPC-PLT-001 §8.9, §8.11, §9.5, §10, Annex A ·
--  plan BUILD_PLAN_R1 W1-03 · deps: W0-02 programme engine, W1-01 rules
--  engine business-day functions, W1-06 exception→RAID trigger)
-- ============================================================================
--
-- Built ON the existing spine. This migration adds NO new tables — only
-- additive columns, one unique index, RPCs and two triggers.
--
--   * maintenance_task_instances gains the FR-MNT-04 provider fields
--     (awaiting_provider_input, provider_id, provider_requested_at,
--     provider_input_log). The instance records WHICH named provider and on
--     WHICH channel — providers are external contacts, not auth users.
--   * checklist_instances gains `summary` — the engine-written annual data
--     pull (FR-QTR-02: findings closed %, evidence counts, trainings,
--     breaches, per-month snapshot figures).
--   * UNIQUE (task_template_id, period) makes generation idempotent — the
--     acceptance bar is "second call, same month = zero new rows".
--
-- TIMING-RULE CONTRACT (maintenance_task_templates.timing_rule jsonb):
--   {"window":"before_month_end"|"month_end_close", "business_days_before_end":n}
--       → due = last business day of the month − n business days (n default 0)
--   {"window":"report_window", "business_day":n}
--       → due = nth business day of the FOLLOWING month (the §9.1 report
--         window: period M's report is assembled at the start of month M+1,
--         because FR-RPT-02 fills sections from data as at the last business
--         day of M). n defaults to programmes.report_due_business_day.
--   {"window":"executive_meeting", "business_day":n}
--       → same anchor as report_window (the exec session presents the issued
--         report); n defaults to report_due_business_day. There is no
--         meeting-date source in the schema — flagged for the plan.
--   Unknown windows RAISE — a silently undated compliance task is worse than
--   a loud authoring error.
--
-- ACTIVE-FROM RULE (FR-MNT-08): active_from_rule
--   {"when_activity_complete":"<activity ref>"} — the task starts only once
--   that programme activity is Complete. Rules with no recognised key FAIL
--   CLOSED (task not yet active → no instance) — generating early is the
--   violation the rule exists to prevent.
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--   1. Generation reads the programme's OWN maintenance_task_templates rows
--      (the working set) — it does NOT re-sync from the template version's
--      content.maintenance_set, because FR-TPL-04 local edits (incl.
--      removals) would be undone every month. Template application at
--      programme creation is W1-05's job.
--   2. FR-MNT-05 names no reason-code enumeration — the spec says "the
--      reason none applies is recorded". The engine enforces a NON-EMPTY
--      evidence_exempt_reason when no evidence attaches (the W0-02 CHECK
--      already enforces presence; free text kept because seeded rows carry
--      free text and no code list exists in the spec).
--   3. "Accepted evidence" = an evidence_items row in the task's programme
--      with at least one stage='accept' decision='accepted' row in the
--      append-only evidence_reviews ledger (the §8.4 acceptance record).
--   4. Status machine on instances: Pending→In progress|Complete|Exception,
--      In progress→Complete|Exception, Exception→In progress|Complete (a
--      late provider input may still close the month's task; the linked
--      RAID row keeps the incident), Complete terminal. Enforced by
--      trg_mti_transition on every write path; 'Complete' may only be set
--      by complete_maintenance_task so the evidence gate has ONE writer.
--   5. FR-MNT-07: "cannot go to review" = the draft→…→ao_review transition.
--      A report enters ao_review only when every task whose template feeds
--      'report' (feeds ILIKE '%report%') for that period is Complete — or
--      when gate_override_reason is non-empty. The override may be recorded
--      only by the programme write roles (the spec's "programme lead" plus
--      the partner/admin delegates who act for them); AO alone may not
--      override the gate on the report they are about to review.
--   6. Generation guard ("service/AO-or-lead"): auth.uid() IS NULL is the
--      scheduler/service path; a JWT caller needs the programme WRITE role
--      set OR is_ao_or_alternate on the owning client. The WRITE set is
--      used rather than literally programme_lead-only because partner
--      admins/consultants run the cadence on the client's behalf.
--   7. Providers get no auth user — request_provider_input records the
--      provider row + channel snapshot on the instance and emits a
--      'maintenance_input_requested' notification_event whose payload
--      carries the provider contact for the dispatcher (W1-08). The
--      'programme_lead' recipient token gives the in-platform copy an
--      audience.
--   8. generate_checklist items instantiate from the programme template's
--      content.quarterly_annual_cycles.<kind>.items — every item gets an
--      evidence slot (evidence_id NULL) + done:false (FR-QTR-01 "checklist
--      with evidence slots"). The annual checklist's items ARE the annual
--      review tasks (the fixture/template's "annual report to the
--      executive" item); the Word/PDF artefact is W3-03's outputs work.
--      checklist_instances.summary carries the year's pull.
--   9. Assignee on generated instances: programmes.programme_lead when the
--      template's owner_role is 'programme_lead', else NULL (other roles
--      resolve to people at task time, not generation time).
--  10. checklist period formats: quarterly 'YYYY-Qn' (n 1..4), annual
--      'YYYY' — validated; the (programme_id, kind, period) UNIQUE makes
--      generation idempotent and returns the existing row's id on re-run.
-- ============================================================================


-- ---------- 0. additive columns + the idempotency unique index ----------

ALTER TABLE public.maintenance_task_instances
  ADD COLUMN IF NOT EXISTS provider_id uuid
    REFERENCES public.external_providers(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.maintenance_task_instances.provider_id IS
  'W1-03 FR-MNT-04: the named provider currently being asked for input '
  '(external contact, not a user) — engine-written.';
ALTER TABLE public.maintenance_task_instances
  ADD COLUMN IF NOT EXISTS provider_requested_at timestamptz;
COMMENT ON COLUMN public.maintenance_task_instances.provider_requested_at IS
  'W1-03: when the current input request went out — engine-written.';
ALTER TABLE public.maintenance_task_instances
  ADD COLUMN IF NOT EXISTS awaiting_provider_input boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.maintenance_task_instances.awaiting_provider_input IS
  'W1-03 FR-MNT-03/04: an input request is outstanding — cleared by '
  'receive_provider_input. Engine-written.';
ALTER TABLE public.maintenance_task_instances
  ADD COLUMN IF NOT EXISTS provider_input_log jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN public.maintenance_task_instances.provider_input_log IS
  'W1-03 FR-MNT-04: append-only-ish log of provider request/response entries '
  '[{type:request|input, at, note?, file_ref?, channel?, contact_email?, by?}]. '
  'Engine-written — appended by the provider RPCs, never rewritten.';

ALTER TABLE public.checklist_instances
  ADD COLUMN IF NOT EXISTS summary jsonb;
COMMENT ON COLUMN public.checklist_instances.summary IS
  'W1-03 FR-QTR-02: the engine-written annual data pull (findings closed %, '
  'evidence counts, trainings, breaches, per-month snapshot figures). NULL '
  'for quarterly rows.';

-- idempotency anchor: one instance per (task template, period). Generation
-- re-runs ON CONFLICT DO NOTHING against this key.
CREATE UNIQUE INDEX IF NOT EXISTS mti_template_period_uq
  ON public.maintenance_task_instances (task_template_id, period);


-- ---------- 1. small predicates/helpers ----------

-- the programme a maintenance instance belongs to (via its template)
CREATE OR REPLACE FUNCTION public.mti_programme(p_instance uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT t.programme_id FROM public.maintenance_task_instances mti
    JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
   WHERE mti.id = p_instance
$$;
COMMENT ON FUNCTION public.mti_programme(uuid) IS
  'W1-03 predicate: the programme owning a maintenance task instance '
  '(through its programme-scoped template row).';

-- has the caller an mti write role? Mirrors the mti_update policy set —
-- STATUS := WRITE + workstream_lead + external_provider + accountable_officer
-- (§4.2 own-scope updates travel through the same surface).
CREATE OR REPLACE FUNCTION public.has_mti_role(p_instance uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.maintenance_task_instances mti
    JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
   WHERE mti.id = p_instance
     AND t.programme_id IS NOT NULL
     AND public.has_programme_role(t.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
              'workstream_lead','external_provider','accountable_officer']))
$$;
COMMENT ON FUNCTION public.has_mti_role(uuid) IS
  'W1-03 predicate: caller may act on this maintenance instance — the '
  'W0-02 mti_update role set.';

-- the generation guard: JWT caller needs the WRITE set or AO/alternate on
-- the owning client; the scheduler/service path (auth.uid() NULL) runs free.
CREATE OR REPLACE FUNCTION public.can_run_cadence(p_programme uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NULL
      OR public.has_programme_role(p_programme,
           ARRAY['partner_admin','partner_consultant','programme_lead','client_admin'])
      OR public.is_ao_or_alternate(public.programme_client(p_programme))
$$;
COMMENT ON FUNCTION public.can_run_cadence(uuid) IS
  'W1-03 predicate (decision 6): service path, programme WRITE roles, or '
  'the client''s AO/named alternate may run cadence generation.';


-- ---------- 2. timing-rule → due date + window (reuses W1-01 §9.1) ----------

CREATE OR REPLACE FUNCTION public.maintenance_task_due(
    p_template uuid, p_month date)
RETURNS TABLE(due_date date, task_window text)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE
  v_t public.maintenance_task_templates%ROWTYPE;
  v_first date;
  v_jur   text;
  v_win   text;
  v_bd    int;
  v_back  int;
BEGIN
  SELECT * INTO v_t FROM public.maintenance_task_templates WHERE id = p_template;
  IF NOT FOUND THEN RETURN; END IF;
  IF p_month IS NULL THEN RETURN; END IF;

  v_first := date_trunc('month', p_month)::date;
  v_jur   := public.programme_jurisdiction(v_t.programme_id);   -- NULL → weekday-only
  v_win   := v_t.timing_rule ->> 'window';
  v_bd    := coalesce((v_t.timing_rule ->> 'business_day')::int,
              (SELECT p.report_due_business_day
                 FROM public.programmes p WHERE p.id = v_t.programme_id));
  v_back  := coalesce((v_t.timing_rule ->> 'business_days_before_end')::int, 0);

  IF v_win IN ('before_month_end','month_end_close') THEN
    RETURN QUERY SELECT
      public.add_business_days(v_jur, public.last_business_day(v_jur, v_first), -v_back),
      v_win;
  ELSIF v_win IN ('report_window','executive_meeting') THEN
    RETURN QUERY SELECT
      public.nth_business_day(v_jur, (v_first + interval '1 month')::date, v_bd),
      v_win;
  ELSE
    RAISE EXCEPTION 'maintenance task template % (%) has unknown timing window % — expected before_month_end|month_end_close|report_window|executive_meeting',
      v_t.code, p_template, v_win;
  END IF;
END $$;
COMMENT ON FUNCTION public.maintenance_task_due(uuid, date) IS
  'W1-03 FR-MNT-02/03: resolve a template''s timing_rule into (due_date, '
  'task_window) for the month containing p_month. report_window and '
  'executive_meeting anchor on the FOLLOWING month''s business days '
  '(period-M report work happens at the start of M+1 — §9.1/FR-RPT-02). '
  'Unknown windows raise.';


-- ---------- 3. FR-MNT-08 active-from evaluation ----------

CREATE OR REPLACE FUNCTION public.maintenance_task_active(
    p_template uuid, p_now timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
DECLARE v_t public.maintenance_task_templates%ROWTYPE; v_ref text;
BEGIN
  SELECT * INTO v_t FROM public.maintenance_task_templates WHERE id = p_template;
  IF NOT FOUND OR NOT v_t.active THEN RETURN false; END IF;
  IF v_t.active_from_rule IS NULL OR v_t.active_from_rule = '{}'::jsonb THEN
    RETURN true;
  END IF;
  -- the only rule kind the engine knows: start once the named activity is
  -- Complete. Unknown rule keys fail closed (decision in the header).
  v_ref := v_t.active_from_rule ->> 'when_activity_complete';
  IF v_ref IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.activities a
     WHERE a.programme_id = v_t.programme_id
       AND a.ref = v_ref
       AND a.status = 'Complete');
END $$;
COMMENT ON FUNCTION public.maintenance_task_active(uuid, timestamptz) IS
  'W1-03 FR-MNT-08: is this template active for generation? False when '
  'active=false, when its active_from_rule''s activity is not yet Complete, '
  'or when the rule carries no recognised key (fail closed).';


-- ---------- 4. generate_maintenance_month (FR-MNT-01/02/03/08) ----------

CREATE OR REPLACE FUNCTION public.generate_maintenance_month(
    p_programme uuid, p_month date, p_now timestamptz DEFAULT now())
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog public.programmes%ROWTYPE;
  v_first date; v_period text;
  v_created int := 0; v_practice uuid; v_client uuid;
  v_inst public.maintenance_task_instances%ROWTYPE;
  v_prov public.external_providers%ROWTYPE;
BEGIN
  IF p_month IS NULL THEN RAISE EXCEPTION 'p_month is required'; END IF;
  IF NOT public.can_run_cadence(p_programme) THEN
    RAISE EXCEPTION 'generate_maintenance_month: no cadence role on programme %', p_programme;
  END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RAISE EXCEPTION 'programme % not found', p_programme; END IF;
  v_client := v_prog.client_org_id;
  v_first  := date_trunc('month', p_month)::date;
  v_period := to_char(v_first, 'YYYY-MM');

  -- materialise this month's instances; provider-bound tasks go straight
  -- to awaiting-provider (FR-MNT-04 — the request is part of the monthly
  -- routine: §10 "On request" timing fires at generation).
  FOR v_inst IN
    INSERT INTO public.maintenance_task_instances
        (task_template_id, period, due_date, task_window, assignee,
         provider_id, provider_requested_at, awaiting_provider_input,
         provider_input_log)
    SELECT t.id, v_period, d.due_date, d.task_window,
           CASE WHEN t.owner_role = 'programme_lead' THEN v_prog.programme_lead END,
           t.input_from_provider_id,
           CASE WHEN t.input_from_provider_id IS NOT NULL THEN p_now END,
           t.input_from_provider_id IS NOT NULL,
           CASE WHEN t.input_from_provider_id IS NOT NULL
                THEN jsonb_build_array(jsonb_build_object(
                       'type','request','at',p_now,
                       'provider_id',t.input_from_provider_id,
                       'channel',(SELECT ep.channel FROM public.external_providers ep
                                   WHERE ep.id = t.input_from_provider_id),
                       'contact_email',(SELECT ep.contact_email FROM public.external_providers ep
                                         WHERE ep.id = t.input_from_provider_id),
                       'by','cadence_generator'))
                ELSE '[]'::jsonb END
      FROM public.maintenance_task_templates t
      JOIN LATERAL (SELECT * FROM public.maintenance_task_due(t.id, v_first)) d ON true
     WHERE t.programme_id = p_programme
       AND public.maintenance_task_active(t.id, p_now)
    ON CONFLICT (task_template_id, period) DO NOTHING
    RETURNING *
  LOOP
    v_created := v_created + 1;
    -- FR-MNT-04: emit the input request for provider-bound instances.
    IF v_inst.provider_id IS NOT NULL THEN
      SELECT * INTO v_prov FROM public.external_providers WHERE id = v_inst.provider_id;
      INSERT INTO public.notification_events (kind, scope, payload, created_at)
      VALUES ('maintenance_input_requested',
              jsonb_build_object('programme_id', p_programme, 'client_org_id', v_client),
              jsonb_build_object(
                'maintenance_task_instance_id', v_inst.id,
                'period', v_period, 'due_date', v_inst.due_date,
                'task_template_id', v_inst.task_template_id,
                'provider', jsonb_build_object(
                    'id', v_prov.id, 'name', v_prov.name, 'kind', v_prov.kind,
                    'contact_email', v_prov.contact_email, 'channel', v_prov.channel),
                'recipients', jsonb_build_array('programme_lead')),
              p_now);
    END IF;
  END LOOP;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c WHERE c.id = v_client;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'maintenance_month.generated',
          jsonb_build_object('programme_id', p_programme, 'period', v_period,
                             'instances_created', v_created, 'at', p_now));
  RETURN v_created;
END $$;
COMMENT ON FUNCTION public.generate_maintenance_month(uuid, date, timestamptz) IS
  'W1-03 FR-MNT-02: materialise the month''s maintenance instances for the '
  'programme (due dates from timing_rule + jurisdiction business days, '
  'FR-MNT-03 windows as task_window, FR-MNT-08 active-from respected, '
  'provider-bound instances requested at once). IDEMPOTENT — a second call '
  'for the same month creates zero rows (UNIQUE task_template_id+period). '
  'Returns the number of NEW instances.';


-- ---------- 5. instance status transitions + completion (FR-MNT-05/06) ----

-- every-path transition + completion invariants. Runs on INSERT and UPDATE:
-- a direct write must satisfy the same data rules as the RPCs.
CREATE OR REPLACE FUNCTION public.trg_mti_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ( (OLD.status = 'Pending'     AND NEW.status IN ('In progress','Complete','Exception'))
          OR (OLD.status = 'In progress' AND NEW.status IN ('Complete','Exception'))
          OR (OLD.status = 'Exception'   AND NEW.status IN ('In progress','Complete')) ) THEN
      RAISE EXCEPTION 'illegal maintenance task transition % → %',
        OLD.status, NEW.status;
    END IF;
  END IF;
  IF NEW.status = 'Exception'
     AND (NEW.exception_reason IS NULL OR btrim(NEW.exception_reason) = '') THEN
    RAISE EXCEPTION 'an exception needs exception_reason (FR-MNT-06 feeds the RAID issue)';
  END IF;
  IF NEW.status = 'Complete' THEN
    IF NEW.evidence_id IS NULL
       AND (NEW.evidence_exempt_reason IS NULL OR btrim(NEW.evidence_exempt_reason) = '') THEN
      RAISE EXCEPTION 'a task is Complete only with evidence attached or a recorded reason none applies (FR-MNT-05)';
    END IF;
    IF NEW.evidence_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.evidence_items e
        JOIN public.maintenance_task_templates t ON t.id = NEW.task_template_id
       WHERE e.id = NEW.evidence_id
         AND e.programme_id = t.programme_id
         AND EXISTS (SELECT 1 FROM public.evidence_reviews r
                      WHERE r.evidence_item_id = e.id
                        AND r.stage = 'accept' AND r.decision = 'accepted')) THEN
      RAISE EXCEPTION 'completion evidence must be an ACCEPTED evidence item of the same programme (FR-MNT-05)';
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_mti_transition() IS
  'W1-03: maintenance instance status machine + FR-MNT-05/06 invariants on '
  'every write path. Complete needs accepted same-programme evidence or a '
  'non-empty exemption reason; Exception needs a reason.';

DROP TRIGGER IF EXISTS mti_transition_rules ON public.maintenance_task_instances;
CREATE TRIGGER mti_transition_rules
BEFORE INSERT OR UPDATE ON public.maintenance_task_instances
FOR EACH ROW EXECUTE FUNCTION public.trg_mti_transition();

-- FR-MNT-05: the ONLY Complete-writer — evidence or exemption enforced.
CREATE OR REPLACE FUNCTION public.complete_maintenance_task(
    p_instance uuid, p_evidence_id uuid DEFAULT NULL,
    p_exemption_reason text DEFAULT NULL, p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mti public.maintenance_task_instances%ROWTYPE;
  v_prog uuid; v_client uuid; v_practice uuid; v_code text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_mti_role(p_instance) THEN
    RAISE EXCEPTION 'complete_maintenance_task: no role on instance %', p_instance;
  END IF;
  SELECT * INTO v_mti FROM public.maintenance_task_instances WHERE id = p_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'maintenance task instance % not found', p_instance; END IF;
  IF p_evidence_id IS NULL
     AND (p_exemption_reason IS NULL OR btrim(p_exemption_reason) = '') THEN
    RAISE EXCEPTION 'a task is Complete only when evidence is attached or the reason none applies is recorded (FR-MNT-05)';
  END IF;
  UPDATE public.maintenance_task_instances
     SET status = 'Complete', evidence_id = p_evidence_id,
         evidence_exempt_reason = p_exemption_reason, completed_on = p_now
   WHERE id = p_instance;

  SELECT t.programme_id, t.code INTO v_prog, v_code
    FROM public.maintenance_task_templates t WHERE t.id = v_mti.task_template_id;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_prog;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'maintenance_task.completed',
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'programme_id', v_prog, 'code', v_code,
                             'period', v_mti.period, 'evidence_id', p_evidence_id,
                             'exempt_reason', p_exemption_reason));
  INSERT INTO public.notification_events (kind, scope, payload, created_at)
  VALUES ('maintenance_task_completed',
          jsonb_build_object('programme_id', v_prog, 'client_org_id', v_client),
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'code', v_code, 'period', v_mti.period,
                             'evidence_id', p_evidence_id,
                             'exempt_reason', p_exemption_reason,
                             'completed_by', auth.uid(),
                             'recipients', jsonb_build_array('programme_lead')),
          p_now);
END $$;
COMMENT ON FUNCTION public.complete_maintenance_task(uuid, uuid, text, timestamptz) IS
  'W1-03 FR-MNT-05: complete an instance — requires an ACCEPTED '
  'same-programme evidence item OR a recorded exemption reason (spec names '
  'no code enumeration; non-empty text enforced — decision 2). Emits '
  'maintenance_task_completed + audit.';


-- ---------- 6. generic status moves (Pending→In progress, →Exception) ----

CREATE OR REPLACE FUNCTION public.update_maintenance_task_status(
    p_instance uuid, p_status text,
    p_exception_reason text DEFAULT NULL, p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mti public.maintenance_task_instances%ROWTYPE;
  v_prog uuid; v_client uuid; v_practice uuid; v_code text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_mti_role(p_instance) THEN
    RAISE EXCEPTION 'update_maintenance_task_status: no role on instance %', p_instance;
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('In progress','Exception') THEN
    RAISE EXCEPTION 'status % must be ''In progress''|''Exception'' — no transition returns to Pending and Complete goes through complete_maintenance_task (FR-MNT-05)', p_status;
  END IF;
  SELECT * INTO v_mti FROM public.maintenance_task_instances WHERE id = p_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'maintenance task instance % not found', p_instance; END IF;

  UPDATE public.maintenance_task_instances
     SET status = p_status,
         exception_reason = coalesce(p_exception_reason, exception_reason)
   WHERE id = p_instance;

  SELECT t.programme_id, t.code INTO v_prog, v_code
    FROM public.maintenance_task_templates t WHERE t.id = v_mti.task_template_id;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_prog;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'maintenance_task.status',
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'programme_id', v_prog, 'code', v_code,
                             'period', v_mti.period,
                             'old_status', v_mti.status, 'new_status', p_status));

  IF p_status = 'Exception' THEN
    INSERT INTO public.notification_events (kind, scope, payload, created_at)
    VALUES ('maintenance_task_exception',
            jsonb_build_object('programme_id', v_prog, 'client_org_id', v_client),
            jsonb_build_object('maintenance_task_instance_id', p_instance,
                               'code', v_code, 'period', v_mti.period,
                               'exception_reason', p_exception_reason,
                               'recipients', jsonb_build_array('programme_lead','accountable_officer')),
            p_now);
  END IF;
END $$;
COMMENT ON FUNCTION public.update_maintenance_task_status(uuid, text, text, timestamptz) IS
  'W1-03: Pending→In progress / →Exception moves (Exception also legal from '
  'In progress; back to In progress/Complete allowed). ''Complete'' is '
  'rejected — complete_maintenance_task owns the evidence gate. The W1-06 '
  'mti_exception_raid trigger auto-raises the RAID issue on →Exception '
  '(FR-MNT-06 — called, not duplicated).';


-- ---------- 7. FR-MNT-03/04 provider input round-trip ----------

CREATE OR REPLACE FUNCTION public.request_provider_input(
    p_instance uuid, p_provider uuid DEFAULT NULL,
    p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mti public.maintenance_task_instances%ROWTYPE;
  v_prov public.external_providers%ROWTYPE;
  v_prog uuid; v_client uuid; v_practice uuid; v_code text; v_label text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_mti_role(p_instance) THEN
    RAISE EXCEPTION 'request_provider_input: no role on instance %', p_instance;
  END IF;
  SELECT * INTO v_mti FROM public.maintenance_task_instances WHERE id = p_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'maintenance task instance % not found', p_instance; END IF;
  IF v_mti.status IN ('Complete','Exception') THEN
    RAISE EXCEPTION 'cannot request provider input on a % task', v_mti.status;
  END IF;

  SELECT t.programme_id, t.code, t.input_from_label INTO v_prog, v_code, v_label
    FROM public.maintenance_task_templates t WHERE t.id = v_mti.task_template_id;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'instance % has no programme', p_instance; END IF;

  -- resolve the provider: explicit argument wins, else the template's bound provider
  SELECT * INTO v_prov FROM public.external_providers
   WHERE id = coalesce(p_provider,
                       (SELECT t.input_from_provider_id
                          FROM public.maintenance_task_templates t
                         WHERE t.id = v_mti.task_template_id));
  IF v_prov IS NULL THEN
    RAISE EXCEPTION 'no named provider for this task — set input_from_provider_id on the template or pass p_provider (FR-MNT-04)';
  END IF;
  IF NOT v_prov.active THEN
    RAISE EXCEPTION 'provider % is inactive', v_prov.name;
  END IF;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_prog;
  IF v_prov.client_org_id IS DISTINCT FROM v_client THEN
    RAISE EXCEPTION 'provider % belongs to a different client', v_prov.name;
  END IF;

  UPDATE public.maintenance_task_instances
     SET awaiting_provider_input = true,
         provider_id = v_prov.id,
         provider_requested_at = p_now,
         provider_input_log = provider_input_log || jsonb_build_object(
            'type','request','at',p_now,'provider_id',v_prov.id,
            'channel',v_prov.channel,'contact_email',v_prov.contact_email,
            'by',auth.uid())
   WHERE id = p_instance;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'maintenance_task.input_requested',
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'programme_id', v_prog, 'code', v_code,
                             'period', v_mti.period, 'provider_id', v_prov.id));
  INSERT INTO public.notification_events (kind, scope, payload, created_at)
  VALUES ('maintenance_input_requested',
          jsonb_build_object('programme_id', v_prog, 'client_org_id', v_client),
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'code', v_code, 'period', v_mti.period,
                             'due_date', v_mti.due_date,
                             'input_from_label', v_label,
                             'provider', jsonb_build_object(
                                 'id', v_prov.id, 'name', v_prov.name,
                                 'kind', v_prov.kind,
                                 'contact_email', v_prov.contact_email,
                                 'channel', v_prov.channel),
                             'recipients', jsonb_build_array('programme_lead')),
          p_now);
END $$;
COMMENT ON FUNCTION public.request_provider_input(uuid, uuid, timestamptz) IS
  'W1-03 FR-MNT-03/04: mark an instance awaiting-provider and emit '
  'maintenance_input_requested. The provider is a named external contact '
  '(no auth user) — contact/channel are recorded on the instance and in the '
  'notification payload for the dispatcher. Re-calling = the reminder.';

CREATE OR REPLACE FUNCTION public.receive_provider_input(
    p_instance uuid, p_note text, p_file_ref text DEFAULT NULL,
    p_now timestamptz DEFAULT now())
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mti public.maintenance_task_instances%ROWTYPE;
  v_prog uuid; v_client uuid; v_practice uuid; v_code text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.has_mti_role(p_instance) THEN
    RAISE EXCEPTION 'receive_provider_input: no role on instance %', p_instance;
  END IF;
  IF (p_note IS NULL OR btrim(p_note) = '') AND p_file_ref IS NULL THEN
    RAISE EXCEPTION 'a provider input needs a note or a file reference';
  END IF;
  SELECT * INTO v_mti FROM public.maintenance_task_instances WHERE id = p_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'maintenance task instance % not found', p_instance; END IF;

  UPDATE public.maintenance_task_instances
     SET awaiting_provider_input = false,
         provider_input_log = provider_input_log || jsonb_build_object(
            'type','input','at',p_now,'note',p_note,'file_ref',p_file_ref,
            'by',auth.uid())
   WHERE id = p_instance;

  SELECT t.programme_id, t.code INTO v_prog, v_code
    FROM public.maintenance_task_templates t WHERE t.id = v_mti.task_template_id;
  SELECT p.client_org_id, c.practice_id INTO v_client, v_practice
    FROM public.programmes p JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = v_prog;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'maintenance_task.input_received',
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'programme_id', v_prog, 'code', v_code,
                             'period', v_mti.period, 'file_ref', p_file_ref));
  INSERT INTO public.notification_events (kind, scope, payload, created_at)
  VALUES ('maintenance_input_received',
          jsonb_build_object('programme_id', v_prog, 'client_org_id', v_client),
          jsonb_build_object('maintenance_task_instance_id', p_instance,
                             'code', v_code, 'period', v_mti.period,
                             'file_ref', p_file_ref,
                             'recipients', jsonb_build_array('programme_lead')),
          p_now);
END $$;
COMMENT ON FUNCTION public.receive_provider_input(uuid, text, text, timestamptz) IS
  'W1-03 FR-MNT-04: record the provider''s response — clears '
  'awaiting_provider_input and appends the input entry (note + optional '
  'file ref) to provider_input_log. Attaching it as completion evidence '
  'goes through the evidence library + complete_maintenance_task.';


-- ---------- 8. generate_checklist (FR-QTR-01/02) ----------

-- the year's pull for the annual review (decision 8). Stored on
-- checklist_instances.summary — frozen at generation like §9.5 snapshots.
CREATE OR REPLACE FUNCTION public.annual_review_figures(
    p_programme uuid, p_year text, p_now timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  WITH yr AS (
    SELECT (p_year || '-01-01')::date AS first,
           (p_year || '-12-31')::date AS last
  ), prog AS (
    SELECT p.id, p.client_org_id FROM public.programmes p WHERE p.id = p_programme
  )
  SELECT jsonb_build_object(
    'year', p_year,
    'generated_at', p_now,
    'register', jsonb_build_object(
      'total', (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p_programme),
      'closed', (SELECT count(*) FROM public.register_items r WHERE r.programme_id = p_programme AND r.status = 'Closed'),
      'closed_pct', (SELECT CASE WHEN count(*) = 0 THEN NULL
                            ELSE round(100.0 * count(*) FILTER (WHERE r.status = 'Closed') / count(*), 1) END
                       FROM public.register_items r WHERE r.programme_id = p_programme),
      'closed_in_year', (SELECT count(*) FROM public.register_items r, yr
                          WHERE r.programme_id = p_programme AND r.status = 'Closed'
                            AND r.accepted_on::date BETWEEN yr.first AND yr.last)),
    'evidence', jsonb_build_object(
      'uploaded_in_year', (SELECT count(*) FROM public.evidence_items e, yr
                            WHERE e.programme_id = p_programme
                              AND e.uploaded_at::date BETWEEN yr.first AND yr.last),
      'decided', (SELECT count(*) FROM public.evidence_items e
                   WHERE e.programme_id = p_programme AND e.review_stage = 'decided'),
      'pending', (SELECT count(*) FROM public.evidence_items e
                   WHERE e.programme_id = p_programme AND e.review_stage <> 'decided')),
    'training', jsonb_build_object(
      'records_in_year', (SELECT count(*) FROM public.training_records tr, yr, prog
                           WHERE tr.client_org_id = prog.client_org_id
                             AND tr.date BETWEEN yr.first AND yr.last),
      'attended_in_year', (SELECT count(*) FROM public.training_records tr, yr, prog
                            WHERE tr.client_org_id = prog.client_org_id
                              AND tr.attendance AND tr.date BETWEEN yr.first AND yr.last)),
    'operational', jsonb_build_object(
      'breaches_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                            WHERE o.client_org_id = prog.client_org_id AND o.type = 'breach'
                              AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'dsrs_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                        WHERE o.client_org_id = prog.client_org_id AND o.type = 'dsr'
                          AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'disclosures_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                               WHERE o.client_org_id = prog.client_org_id AND o.type = 'disclosure'
                                 AND o.reported_at::date BETWEEN yr.first AND yr.last),
      'optouts_in_year', (SELECT count(*) FROM public.operational_records o, yr, prog
                           WHERE o.client_org_id = prog.client_org_id AND o.type = 'optout'
                             AND o.reported_at::date BETWEEN yr.first AND yr.last)),
    'maintenance', jsonb_build_object(
      'instances', (SELECT count(*) FROM public.maintenance_task_instances mti
                      JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                     WHERE t.programme_id = p_programme
                       AND mti.period LIKE p_year || '-%'),
      'complete', (SELECT count(*) FROM public.maintenance_task_instances mti
                     JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                    WHERE t.programme_id = p_programme AND mti.status = 'Complete'
                      AND mti.period LIKE p_year || '-%'),
      'exceptions', (SELECT count(*) FROM public.maintenance_task_instances mti
                      JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
                     WHERE t.programme_id = p_programme AND mti.status = 'Exception'
                       AND mti.period LIKE p_year || '-%')),
    -- per-month frozen figures from §9.5 snapshots (only months that ran)
    'months', (SELECT coalesce(jsonb_object_agg(s.period,
                     jsonb_build_object('rag', s.snapshot->>'rag',
                                        'maintenance_done', s.snapshot->'maintenance_done',
                                        'maintenance_overdue', s.snapshot->'maintenance_overdue',
                                        'register_closed', s.snapshot->'register_closed',
                                        'activities_overdue', s.snapshot->'activities_overdue')
                     ORDER BY s.period), '{}'::jsonb)
                 FROM public.monthly_snapshots s
                WHERE s.programme_id = p_programme
                  AND s.period LIKE p_year || '-%'))
$$;
COMMENT ON FUNCTION public.annual_review_figures(uuid, text, timestamptz) IS
  'W1-03 FR-QTR-02: the annual data pull — findings closed %, evidence '
  'counts, trainings, breaches/DSRs/etc., maintenance totals and the year''s '
  'monthly snapshot figures. Stored on checklist_instances.summary.';


CREATE OR REPLACE FUNCTION public.generate_checklist(
    p_programme uuid, p_kind text, p_period text,
    p_now timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog public.programmes%ROWTYPE;
  v_items jsonb; v_summary jsonb; v_id uuid; v_practice uuid;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('quarterly','annual') THEN
    RAISE EXCEPTION 'checklist kind % must be quarterly|annual', p_kind;
  END IF;
  IF p_kind = 'quarterly' AND coalesce(p_period,'') !~ '^[0-9]{4}-Q[1-4]$' THEN
    RAISE EXCEPTION 'quarterly period % must look like YYYY-Qn', p_period;
  END IF;
  IF p_kind = 'annual' AND coalesce(p_period,'') !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'annual period % must look like YYYY', p_period;
  END IF;
  IF NOT public.can_run_cadence(p_programme) THEN
    RAISE EXCEPTION 'generate_checklist: no cadence role on programme %', p_programme;
  END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme;
  IF NOT FOUND THEN RAISE EXCEPTION 'programme % not found', p_programme; END IF;

  -- instantiate the template's checklist items (decision 8)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
             'ref', item ->> 'ref',
             'label', coalesce(item ->> 'label', item ->> 'task'),
             'evidence_required', coalesce((item ->> 'evidence_required')::boolean, false),
             'evidence_id', NULL,
             'done', false)
           ORDER BY ord), '[]'::jsonb)
    INTO v_items
    FROM public.programme_template_versions v,
         LATERAL jsonb_array_elements(
           coalesce(v.content -> 'quarterly_annual_cycles' -> p_kind -> 'items',
                    '[]'::jsonb)) WITH ORDINALITY AS u(item, ord)
   WHERE v.id = v_prog.template_version_id;
  IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'no % checklist items on the programme''s template version (content.quarterly_annual_cycles.%.items)', p_kind, p_kind;
  END IF;

  v_summary := CASE WHEN p_kind = 'annual'
                    THEN public.annual_review_figures(p_programme, p_period, p_now)
                    ELSE NULL END;

  INSERT INTO public.checklist_instances
      (programme_id, kind, period, items, summary, generated_on)
  VALUES (p_programme, p_kind, p_period, v_items, v_summary, p_now::date)
  ON CONFLICT (programme_id, kind, period) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN                       -- already generated: return it
    SELECT id INTO v_id FROM public.checklist_instances
     WHERE programme_id = p_programme AND kind = p_kind AND period = p_period;
    RETURN v_id;
  END IF;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'checklist.generated',
          jsonb_build_object('programme_id', p_programme, 'kind', p_kind,
                             'period', p_period, 'checklist_instance_id', v_id,
                             'items', jsonb_array_length(v_items)));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.generate_checklist(uuid, text, text, timestamptz) IS
  'W1-03 FR-QTR-01/02: instantiate the template''s quarterly/annual '
  'checklist with evidence slots; annual additionally freezes the year''s '
  'figures into summary. Idempotent per (programme, kind, period) — a '
  're-run returns the existing row''s id.';


-- ---------- 9. FR-MNT-07 report gate + helpers ----------

-- the feeding tasks still open for a report period (drives the gate + UI).
CREATE OR REPLACE FUNCTION public.report_open_feeding_tasks(
    p_programme uuid, p_period text)
RETURNS TABLE(code text, task text, status text, due_date date)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT t.code, t.task, mti.status, mti.due_date
    FROM public.maintenance_task_instances mti
    JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
   WHERE t.programme_id = p_programme
     AND mti.period = p_period
     AND t.feeds ILIKE '%report%'
     AND mti.status <> 'Complete'
   ORDER BY t.sort, t.code
$$;
COMMENT ON FUNCTION public.report_open_feeding_tasks(uuid, text) IS
  'W1-03 FR-MNT-07: report-feeding maintenance tasks still open for a '
  'period — the blocker list behind the ao_review gate.';

-- runs BEFORE report_transition_gate (alphabetical): entering ao_review is
-- blocked while feeding tasks are open, unless a gate reason is recorded.
-- Also guards WHO may set that reason (decision 5).
CREATE OR REPLACE FUNCTION public.trg_report_maintenance_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_codes text;
BEGIN
  IF NEW.gate_override_reason IS DISTINCT FROM OLD.gate_override_reason
     AND NEW.gate_override_reason IS NOT NULL
     AND btrim(NEW.gate_override_reason) <> ''
     AND auth.uid() IS NOT NULL
     AND NOT public.has_programme_role(NEW.programme_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'only the programme lead or a partner delegate may record the maintenance gate reason (FR-MNT-07)';
  END IF;
  IF NEW.status = 'ao_review' AND OLD.status IS DISTINCT FROM 'ao_review' THEN
    SELECT string_agg(code, ', ' ORDER BY code) INTO v_codes
      FROM public.report_open_feeding_tasks(NEW.programme_id, NEW.period);
    IF v_codes IS NOT NULL
       AND (NEW.gate_override_reason IS NULL OR btrim(NEW.gate_override_reason) = '') THEN
      RAISE EXCEPTION 'report % cannot go to review — maintenance tasks feeding it are still open: %. Record gate_override_reason to proceed (FR-MNT-07)',
        NEW.period, v_codes;
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_report_maintenance_gate() IS
  'W1-03 FR-MNT-07: a report enters ao_review only when its report-feeding '
  'maintenance tasks for the period are Complete — or when a programme '
  'write role recorded gate_override_reason (prints in the report).';

DROP TRIGGER IF EXISTS report_maintenance_gate ON public.programme_reports;
CREATE TRIGGER report_maintenance_gate
BEFORE UPDATE ON public.programme_reports
FOR EACH ROW EXECUTE FUNCTION public.trg_report_maintenance_gate();


-- ---------- 10. reads: 12-month history + period status ----------

-- FR-MNT-10: completion history per task — evidence that controls operate.
CREATE OR REPLACE FUNCTION public.maintenance_task_history(
    p_template uuid, p_months int DEFAULT 12)
RETURNS SETOF public.maintenance_task_instances
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT mti.* FROM public.maintenance_task_instances mti
   WHERE mti.task_template_id = p_template
   ORDER BY mti.period DESC
   LIMIT greatest(coalesce(p_months, 12), 1)
$$;
COMMENT ON FUNCTION public.maintenance_task_history(uuid, int) IS
  'W1-03 FR-MNT-10: last p_months (default 12) instances of one task, '
  'newest first — the per-task completion history.';

-- FR-MNT-09/console feed: per-period counts (overdue computed at p_now).
CREATE OR REPLACE FUNCTION public.maintenance_period_status(
    p_programme uuid, p_month date, p_now timestamptz DEFAULT now())
RETURNS TABLE(total int, complete int, exception int,
              in_progress int, pending int, awaiting_provider int, overdue int)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT count(*)::int,
         count(*) FILTER (WHERE mti.status = 'Complete')::int,
         count(*) FILTER (WHERE mti.status = 'Exception')::int,
         count(*) FILTER (WHERE mti.status = 'In progress')::int,
         count(*) FILTER (WHERE mti.status = 'Pending')::int,
         count(*) FILTER (WHERE mti.awaiting_provider_input)::int,
         count(*) FILTER (WHERE mti.status <> 'Complete'
                          AND mti.due_date IS NOT NULL
                          AND mti.due_date < p_now::date)::int
    FROM public.maintenance_task_instances mti
    JOIN public.maintenance_task_templates t ON t.id = mti.task_template_id
   WHERE t.programme_id = p_programme
     AND mti.period = to_char(date_trunc('month', p_month), 'YYYY-MM')
$$;
COMMENT ON FUNCTION public.maintenance_period_status(uuid, date, timestamptz) IS
  'W1-03 FR-MNT-09/FR-PCN-01 feed: one row of per-period maintenance counts '
  '(overdue vs p_now) for console tiles and the maintenance screen.';


-- ---------- 11. grants (W0-00 convention: revoke all, grant the surface) --
REVOKE EXECUTE ON FUNCTION
  public.mti_programme(uuid),
  public.has_mti_role(uuid),
  public.can_run_cadence(uuid),
  public.maintenance_task_due(uuid, date),
  public.maintenance_task_active(uuid, timestamptz),
  public.generate_maintenance_month(uuid, date, timestamptz),
  public.trg_mti_transition(),
  public.complete_maintenance_task(uuid, uuid, text, timestamptz),
  public.update_maintenance_task_status(uuid, text, text, timestamptz),
  public.request_provider_input(uuid, uuid, timestamptz),
  public.receive_provider_input(uuid, text, text, timestamptz),
  public.annual_review_figures(uuid, text, timestamptz),
  public.generate_checklist(uuid, text, text, timestamptz),
  public.report_open_feeding_tasks(uuid, text),
  public.trg_report_maintenance_gate(),
  public.maintenance_task_history(uuid, int),
  public.maintenance_period_status(uuid, date, timestamptz)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.mti_programme(uuid),
  public.has_mti_role(uuid),
  public.maintenance_task_due(uuid, date),
  public.maintenance_task_active(uuid, timestamptz),
  public.generate_maintenance_month(uuid, date, timestamptz),
  public.complete_maintenance_task(uuid, uuid, text, timestamptz),
  public.update_maintenance_task_status(uuid, text, text, timestamptz),
  public.request_provider_input(uuid, uuid, timestamptz),
  public.receive_provider_input(uuid, text, text, timestamptz),
  public.annual_review_figures(uuid, text, timestamptz),
  public.generate_checklist(uuid, text, text, timestamptz),
  public.report_open_feeding_tasks(uuid, text),
  public.maintenance_task_history(uuid, int),
  public.maintenance_period_status(uuid, date, timestamptz)
TO authenticated;
-- can_run_cadence + the two trigger functions stay internal (no grant).
