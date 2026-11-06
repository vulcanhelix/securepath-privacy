-- ============================================================================
-- W2-08 — monthly report builder RPC checks (migration 20261106000014,
-- spec §8.6 FR-RPT-01..04/06, §9.5, NFR-09, AT-17, FR-MNT-07 gate).
--
-- Self-contained: own W208 namespace (@w208.test users, 'W208 …' practices,
-- uuid prefixes a208/b208/c208/d208/e208), never touches the TESTFIX world.
-- Simulates JWT callers via SET ROLE authenticated + request.jwt.claims, the
-- e2e_role_assignments.sql style. Re-runnable: wipes its namespace first and
-- tears it down at the end.
--
-- Run (CI/ephemeral stack; scratch image needs the auth shim — see
-- e2e_template_engine.sql's header):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -f app/tests/e2e_report_builder.sql
-- ============================================================================
\set QUIET on
\pset pager off
\o /dev/null

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- expect p_sql to raise an error whose message matches p_like (ILIKE)
CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text, p_like text, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE p_like THEN
      RAISE NOTICE 'PASS % — %', label, SQLERRM;
    ELSE
      RAISE WARNING 'FAIL % — wrong error: %', label, SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE WARNING 'FAIL % — no error raised', label;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.t(boolean, text), pg_temp.refused(text, text, text) TO authenticated;

-- ---------- teardown of any previous run ----------
CREATE OR REPLACE FUNCTION pg_temp.w208_wipe() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.programme_reports DISABLE TRIGGER report_transition_gate;
  DELETE FROM public.programme_reports WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W208%');
  ALTER TABLE public.programme_reports ENABLE TRIGGER report_transition_gate;
  DELETE FROM public.monthly_snapshots WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W208%');
  DELETE FROM public.audit_log WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W208%');
  DELETE FROM public.designations WHERE client_org_id IN
    (SELECT c.id FROM public.client_orgs c JOIN public.practices p ON p.id = c.practice_id
      WHERE p.name LIKE 'W208%');
  DELETE FROM public.programmes WHERE name LIKE 'W208%';
  DELETE FROM public.programme_templates WHERE framework = 'w208_test';
  DELETE FROM public.client_orgs WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W208%');
  DELETE FROM public.users WHERE email LIKE '%@w208.test';
  DELETE FROM auth.users WHERE email LIKE '%@w208.test';
  DELETE FROM public.practices WHERE name LIKE 'W208%';
END $$;
SELECT pg_temp.w208_wipe();

-- ---------- fixtures ----------
INSERT INTO auth.users (id, instance_id, email, encrypted_password, aud, role,
    email_confirmed_at, created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, email_change_token_current,
    recovery_token, reauthentication_token, phone_change, phone_change_token,
    raw_app_meta_data, raw_user_meta_data)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    crypt('x', gen_salt('bf')), 'authenticated', 'authenticated',
    now(), now(), now(), '', '', '', '', '', '', '', '',
    '{"provider":"email","providers":["email"]}', '{}'
FROM (VALUES
  ('a2080000-0000-0000-0000-000000000001'::uuid, 'pl@w208.test'),
  ('a2080000-0000-0000-0000-000000000002'::uuid, 'ao@w208.test'),
  ('a2080000-0000-0000-0000-000000000003'::uuid, 'alt@w208.test'),
  ('a2080000-0000-0000-0000-000000000004'::uuid, 'exec@w208.test'),
  ('a2080000-0000-0000-0000-000000000005'::uuid, 'other@w208.test')
) AS u(id, email);
INSERT INTO public.users (id, email, full_name)
SELECT id, email, 'W208 ' || split_part(email, '@', 1) FROM auth.users WHERE email LIKE '%@w208.test';

INSERT INTO public.practices (id, name) VALUES
  ('b2080000-0000-0000-0000-00000000000a', 'W208 Alpha'),
  ('b2080000-0000-0000-0000-00000000000b', 'W208 Beta');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES   -- jurisdiction NULL → weekday calendar
  ('c2080000-0000-0000-0000-000000000001', 'b2080000-0000-0000-0000-00000000000a', 'W208 Client One'),
  ('c2080000-0000-0000-0000-000000000002', 'b2080000-0000-0000-0000-00000000000b', 'W208 Client Two');

INSERT INTO public.programme_templates (id, framework, edition, name)
VALUES ('e2080000-0000-0000-0000-000000000001', 'w208_test', 'W208', 'W208 Template');
INSERT INTO public.programme_template_versions (id, template_id, number, status, content)
VALUES ('e2080001-0000-0000-0000-000000000001', 'e2080000-0000-0000-0000-000000000001', 1, 'draft',
  '{"report_structure": {"due_business_day": 5, "sections": [
      {"key": "executive_summary", "title": "W208 Summary"},
      {"key": "register_progress"},
      {"key": "figures_only", "figures": ["maintenance_done", "register_open"], "narrative": "none"},
      {"key": "notes", "narrative": "optional"}]}}'::jsonb);

INSERT INTO public.programmes (id, client_org_id, template_version_id, name, start_date,
                               total_weeks, report_due_business_day) VALUES
  ('d2080000-0000-0000-0000-000000000001', 'c2080000-0000-0000-0000-000000000001',
   'e2080001-0000-0000-0000-000000000001', 'W208 Programme One', DATE '2026-09-07', 20, 5),
  ('d2080000-0000-0000-0000-000000000002', 'c2080000-0000-0000-0000-000000000002',
   NULL, 'W208 Programme Two', DATE '2026-09-07', 20, 5);

-- pl: programme_lead (WRITE) · ao: accountable_officer · alt: executive +
-- named_alternate designation · exec: executive only · other: partner_admin
-- of the OTHER partner (cross-tenant)
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a2080000-0000-0000-0000-000000000001','client','programme_lead','client','c2080000-0000-0000-0000-000000000001'),
  ('a2080000-0000-0000-0000-000000000002','client','accountable_officer','client','c2080000-0000-0000-0000-000000000001'),
  ('a2080000-0000-0000-0000-000000000003','client','executive','client','c2080000-0000-0000-0000-000000000001'),
  ('a2080000-0000-0000-0000-000000000004','client','executive','client','c2080000-0000-0000-0000-000000000001'),
  ('a2080000-0000-0000-0000-000000000005','partner','partner_admin','partner','b2080000-0000-0000-0000-00000000000b');
INSERT INTO public.designations (client_org_id, role, person, date_designated)
VALUES ('c2080000-0000-0000-0000-000000000001', 'named_alternate',
        'a2080000-0000-0000-0000-000000000003', DATE '2026-09-01');

-- one report-feeding maintenance task for 2026-10, still open
INSERT INTO public.maintenance_task_templates (id, programme_id, code, task, timing_rule, feeds)
VALUES ('e2080002-0000-0000-0000-000000000001', 'd2080000-0000-0000-0000-000000000001',
        'W208-M1', 'W208 provider backup confirmation', '{"window":"before_month_end"}', 'Report');
INSERT INTO public.maintenance_task_instances (id, task_template_id, period, status)
VALUES ('e2080003-0000-0000-0000-000000000001', 'e2080002-0000-0000-0000-000000000001', '2026-10', 'Pending');


-- ============================================================================
-- 1. create_monthly_report — snapshot-bound + idempotent (FR-RPT-01/02)
-- ============================================================================
SELECT pg_temp.t(NOT EXISTS (SELECT 1 FROM public.monthly_snapshots
                              WHERE programme_id = 'd2080000-0000-0000-0000-000000000001'),
  '01 precondition: no snapshot yet for programme one');

-- first create on the service path (scheduler; auth.uid() NULL honours the
-- injected clock), then the programme lead re-creates: same row back
SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001', '2026-10',
                                    '2026-11-02 09:00+00') AS r10 \gset
SELECT pg_temp.refused($$SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001',
    '2026-11', '2026-11-10 09:00+00')$$, '%last business day%',
  '03 no report from mid-month figures (snapshot day not reached)');
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001', '2026-10') AS r10b \gset
SELECT pg_temp.t(:'r10' = :'r10b', '02 create is idempotent per programme + period (same id)');
SELECT pg_temp.refused($$SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001',
    '2099-12', '2100-01-05 09:00+00')$$, '%last business day%',
  '03b a JWT caller cannot inject a clock to fake the snapshot day');
RESET ROLE; SET request.jwt.claims = '';

SELECT pg_temp.t(
  (SELECT r.snapshot_id = s.id FROM public.programme_reports r
     JOIN public.monthly_snapshots s ON s.programme_id = r.programme_id AND s.period = r.period
    WHERE r.id = :'r10'),
  '04 report bound to the period''s snapshot (written via write_monthly_snapshot)');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.programme_reports WHERE programme_id = 'd2080000-0000-0000-0000-000000000001' AND period = '2026-10') = 1
  AND (SELECT count(*) FROM public.monthly_snapshots WHERE programme_id = 'd2080000-0000-0000-0000-000000000001' AND period = '2026-10') = 1,
  '05 idempotent create left exactly one report and one snapshot');
SELECT pg_temp.t(
  (SELECT jsonb_array_length(sections -> 'structure') = 4
      AND sections -> 'structure' -> 0 ->> 'title' = 'W208 Summary'
      AND due_on = DATE '2026-11-06' AND status = 'draft'
     FROM public.programme_reports WHERE id = :'r10'),
  '06 structure frozen from the template; due = 5th business day of next month');

-- service path (scheduler, auth.uid() NULL) on P2: fallback structure
SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000002', '2026-10',
                                    '2026-11-02 09:00+00') AS r2 \gset
SELECT pg_temp.t(
  (SELECT sections -> 'structure' -> 0 ->> 'key' = 'monthly_figures'
     FROM public.programme_reports WHERE id = :'r2'),
  '07 template without report_structure gets the fallback structure');

-- ============================================================================
-- 2. scope + role guards
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001', '2026-09', '2026-10-30 19:00+00')$$,
  '%no write role%', '08 executive (no write role) cannot create a report');
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"headline":"x"}')$$,
  '%no write role%', '09 executive cannot edit the draft');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT * FROM public.list_reports('d2080000-0000-0000-0000-000000000001')$$,
  '%not visible%', '10 cross-tenant partner cannot list another partner''s reports');
SELECT pg_temp.refused($$SELECT public.report_document('$$ || :'r10' || $$')$$,
  '%not visible%', '11 cross-tenant partner cannot read the report document');
RESET ROLE; SET request.jwt.claims = '';

-- ============================================================================
-- 3. snapshot figures are not editable (§9.5)
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"figures":{"maintenance_done":99}}')$$,
  '%snapshot figures%', '12 update_report_draft refuses a figures key');
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"narrative":{"executive_summary":{"register_open":0}}}')$$,
  '%must be text%', '13 narrative cannot smuggle figure objects');
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"narrative":{"figures_only":"x"}}')$$,
  '%figures-only%', '14 a figures-only section takes no narrative');
SELECT pg_temp.refused($$UPDATE public.monthly_snapshots SET snapshot = '{}' WHERE programme_id = 'd2080000-0000-0000-0000-000000000001'$$,
  '%permission denied%', '15 direct snapshot UPDATE denied to tenant roles');
SELECT pg_temp.refused($$UPDATE public.programme_reports SET snapshot_id = NULL WHERE id = '$$ || :'r10' || $$'$$,
  '%permission denied%', '16 snapshot_id is write-protected for tenant roles');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.refused($$UPDATE public.programme_reports SET snapshot_id = (SELECT id FROM public.monthly_snapshots WHERE programme_id = 'd2080000-0000-0000-0000-000000000002') WHERE id = '$$ || :'r10' || $$'$$,
  '%snapshot figures cannot be changed%', '17 even a definer/service write cannot re-bind the snapshot');
SELECT pg_temp.t(
  (SELECT (f ->> 'value')::int = (s.snapshot ->> 'maintenance_done')::int
     FROM jsonb_array_elements(public.report_document(:'r10') -> 'sections') sec,
          jsonb_array_elements(sec -> 'figures') f,
          public.monthly_snapshots s
    WHERE sec ->> 'key' = 'figures_only' AND f ->> 'key' = 'maintenance_done'
      AND s.programme_id = 'd2080000-0000-0000-0000-000000000001' AND s.period = '2026-10'),
  '18 report_document resolves figures from the bound snapshot');

-- ============================================================================
-- 4. inputs outstanding + workflow + FR-MNT-07 gate
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FILTER (WHERE kind = 'maintenance_task' AND ref = 'W208-M1') = 1
      AND count(*) FILTER (WHERE kind = 'narrative') = 2
     FROM public.report_inputs_outstanding(:'r10')),
  '19 inputs outstanding: open feeding task + 2 required narratives');
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'inputs_complete')$$,
  '%narrative still missing%', '20 inputs_complete refused while narrative is missing');
SELECT public.update_report_draft(:'r10',
  '{"narrative":{"executive_summary":"W208 progress this month.","register_progress":"W208 two items moved."},
    "headline":"W208 headline","overall_rag":"Amber"}');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.report_inputs_outstanding(:'r10') WHERE kind = 'narrative') = 0,
  '21 narrative saved through the RPC clears the narrative inputs');
SELECT public.transition_report(:'r10', 'inputs_complete');
RESET ROLE; SET request.jwt.claims = '';

-- AO (not a write role): gate blocks, and the AO may not record the override
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'ao_review')$$,
  '%maintenance tasks feeding it are still open: W208-M1%', '22 maintenance gate blocks AO review (reason surfaced)');
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'ao_review', NULL, 'AO says skip')$$,
  '%only the programme lead or a partner delegate may record%', '23 gate override refused for a role the gate does not allow');
SELECT pg_temp.refused($$UPDATE public.programme_reports SET status = 'ao_review', gate_override_reason = 'direct' WHERE id = '$$ || :'r10' || $$'$$,
  '%only the programme lead or a partner delegate may record%', '24 trigger also refuses the AO override on the direct path');
RESET ROLE; SET request.jwt.claims = '';

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.transition_report(:'r10', 'ao_review', NULL, 'W208 provider input late — noted in the report');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status = 'ao_review' AND gate_override_reason LIKE 'W208 provider%'
     FROM public.programme_reports WHERE id = :'r10'),
  '25 programme lead''s override reason opens AO review');

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"headline":"late edit"}')$$,
  '%only draft or inputs_complete%', '26 narrative locked in AO review (RPC)');
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'signed')$$,
  '%only the accountable officer or named alternate may sign%', '27 programme lead (non-AO) cannot sign');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'signed')$$,
  '%only the accountable officer or named alternate may sign%', '28 executive cannot sign');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.refused($$UPDATE public.programme_reports SET headline = 'AO rewrite' WHERE id = '$$ || :'r10' || $$'$$,
  '%content is locked%', '29 content locked in AO review on the direct path too');
SELECT public.transition_report(:'r10', 'signed', 'W208 reviewed');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'issued')$$,
  '%may issue%', '30 executive cannot issue');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.transition_report(:'r10', 'issued');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status = 'issued' AND issued_on IS NOT NULL
      AND issued_by = 'a2080000-0000-0000-0000-000000000001'
      AND reference = 'RPT-2026-10-v1'
      AND jsonb_array_length(signatures) = 1
      AND signatures -> 0 ->> 'role' = 'accountable_officer'
      AND signatures -> 0 ->> 'user' = 'a2080000-0000-0000-0000-000000000002'
     FROM public.programme_reports WHERE id = :'r10'),
  '31 AO signature + issuer/when/reference recorded');

-- ============================================================================
-- 5. issued report is immutable (NFR-09 / AT-17)
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.update_report_draft('$$ || :'r10' || $$', '{"headline":"after issue"}')$$,
  '%only draft or inputs_complete%', '32 issued report cannot be updated via the RPC');
SELECT pg_temp.refused($$UPDATE public.programme_reports SET commentary = 'x' WHERE id = '$$ || :'r10' || $$'$$,
  '%cannot change afterwards%', '33 issued report cannot be updated directly');
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r10' || $$', 'signed')$$,
  '%issued report cannot change%', '34 issued report cannot be transitioned');
SELECT pg_temp.refused($$DELETE FROM public.programme_reports WHERE id = '$$ || :'r10' || $$'$$,
  '%permission denied%', '35 tenant roles cannot delete reports');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.refused($$DELETE FROM public.programme_reports WHERE id = '$$ || :'r10' || $$'$$,
  '%cannot be deleted%', '36 issued report cannot be deleted even by the service role');
-- AT-17: status changes after the snapshot leave the issued report unchanged
UPDATE public.maintenance_task_instances SET status = 'Complete', evidence_exempt_reason = 'W208 test'
 WHERE id = 'e2080003-0000-0000-0000-000000000001';
SELECT pg_temp.t(
  (SELECT (f ->> 'value')::int FROM jsonb_array_elements(public.report_document(:'r10') -> 'sections') sec,
          jsonb_array_elements(sec -> 'figures') f
    WHERE sec ->> 'key' = 'figures_only' AND f ->> 'key' = 'maintenance_done') = 0
  AND (public.monthly_snapshot_figures('d2080000-0000-0000-0000-000000000001',
         DATE '2026-10-01') ->> 'maintenance_done')::int = 1,   -- live figure moved
  '37 AT-17: later task completion leaves the issued report''s figures unchanged');

-- correction = new version row
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.create_report_correction(:'r10', 'W208 typo in summary') AS r10v2 \gset
SELECT pg_temp.refused($$SELECT public.create_report_correction('$$ || :'r10' || $$', 'again')$$,
  '%already%', '38 only one open correction per period');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT n.version = 2 AND n.supersedes_id = o.id AND n.snapshot_id = o.snapshot_id
      AND n.status = 'draft' AND o.status = 'issued' AND o.reference = 'RPT-2026-10-v1'
      AND n.sections -> 'narrative' ->> 'executive_summary' = 'W208 progress this month.'
     FROM public.programme_reports n, public.programme_reports o
    WHERE n.id = :'r10v2' AND o.id = :'r10'),
  '39 correction is a new version on the same snapshot; the issued row is untouched');

-- ============================================================================
-- 6. late flag (FR-RPT-06) on both sides of the due date
-- ============================================================================
-- September report on P1: due = 5th business day of Oct 2026 = Wed 2026-10-07
SELECT public.create_monthly_report('d2080000-0000-0000-0000-000000000001', '2026-09',
                                    '2026-10-01 09:00+00') AS r09 \gset
SELECT pg_temp.t(
  (SELECT due_on = DATE '2026-10-07' AND NOT late AND days_late = 0
     FROM public.list_reports('d2080000-0000-0000-0000-000000000001', '2026-10-07 12:00+00')
    WHERE id = :'r09'),
  '40 not late on the due business day itself');
SELECT pg_temp.t(
  (SELECT late AND days_late = 1
     FROM public.list_reports('d2080000-0000-0000-0000-000000000001', '2026-10-08 12:00+00')
    WHERE id = :'r09'),
  '41 late the day after the due business day while not issued');
SELECT pg_temp.t(
  (SELECT bool_and(late = ((SELECT issued_on::date FROM public.programme_reports WHERE id = :'r10') > DATE '2026-11-06'))
     FROM (SELECT late FROM public.list_reports('d2080000-0000-0000-0000-000000000001', '2026-11-01 00:00+00') WHERE id = :'r10'
           UNION ALL
           SELECT late FROM public.list_reports('d2080000-0000-0000-0000-000000000001', '2031-01-01 00:00+00') WHERE id = :'r10') x),
  '42 an issued report''s late flag is fixed by its issue date, not the clock');
SELECT pg_temp.t(
  (SELECT a.late = b.late AND b.is_latest AND NOT a.is_latest
     FROM public.list_reports('d2080000-0000-0000-0000-000000000001', '2031-01-01 00:00+00') a,
          public.list_reports('d2080000-0000-0000-0000-000000000001', '2031-01-01 00:00+00') b
    WHERE a.id = :'r10' AND b.id = :'r10v2'),
  '43 a correction inherits the period''s first-issue late flag');

-- alternate signs (designation-based) on the September report
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.update_report_draft(:'r09',
  '{"narrative":{"executive_summary":"W208 Sept.","register_progress":"W208 Sept register."}}');
SELECT public.transition_report(:'r09', 'inputs_complete');
SELECT public.transition_report(:'r09', 'ao_review');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.refused($$SELECT public.transition_report('$$ || :'r09' || $$', 'inputs_complete')$$,
  '%needs a note%', '44 returning from review requires a note');
SET request.jwt.claims = '{"sub":"a2080000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT public.transition_report(:'r09', 'signed');
RESET ROLE; SET request.jwt.claims = '';
SELECT pg_temp.t(
  (SELECT status = 'signed' AND signatures -> 0 ->> 'role' = 'alternate'
     FROM public.programme_reports WHERE id = :'r09'),
  '45 the named alternate may sign');
SELECT pg_temp.refused($$UPDATE public.programme_reports SET headline = 'post-sign' WHERE id = '$$ || :'r09' || $$'$$,
  '%content is locked%', '46 signed report content is locked (NFR-09)');

-- ---------- teardown ----------
SELECT pg_temp.w208_wipe();
