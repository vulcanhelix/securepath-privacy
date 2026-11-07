-- ============================================================================
-- W3-04 (#45) exports — psql acceptance checks for
-- 20261106000027_exports.sql (spec §11): row parity vs the tables, the
-- caller-visible-only rule, cross-tenant refusal, the admins-only audit
-- extract, and the disclosure audit_log rows every export writes.
--
-- SELF-CONTAINED: seeds its own @w3ex.test / 'W3EX%' namespace (two partners,
-- two clients, three programmes) and never reads or mutates the shared
-- TESTFIX world. Re-runnable: the namespace is wiped first and torn down at
-- the end. Staged rows are written claim-free (service path) — the evidence
-- accept review is staged directly because trg_evidence_review_gate skips
-- checks when auth.uid() IS NULL.
--
-- JWT callers are simulated with SET ROLE authenticated + request.jwt.claims
-- (e2e_role_assignments.sql pattern). SET ROLE and the claims GUC outlive
-- COMMIT, so every block ends with RESET ROLE + RESET request.jwt.claims.
--
-- Actors (a3e70000-…-000N):
--   U1 padmin   partner_admin, partner A     — everything on A
--   U2 pl       programme_lead, programme P1 — P1 only
--   U3 contrib  client_contributor, client A — client A
--   U4 wl       workstream_lead, workstream W1 (P1) — W4-D3 programme read
--   U5 badmin   partner_admin, partner B     — cross-tenant
--   U6 ro       read_only, partner A         — read surface on A
--   U7 ao       accountable_officer, client A — accept-review reviewer
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_exports.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text, p_like text, label text)
RETURNS void LANGUAGE plpgsql AS $$
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

-- ---------- wipe any earlier run ----------
CREATE OR REPLACE FUNCTION pg_temp.w3ex_wipe() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.audit_log WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W3EX%')
    OR user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w3ex.test');
  -- issued rows refuse every delete path (§9.5) — the test's own ledger is
  -- exempted for the wipe only, same pattern as e2e_report_builder
  ALTER TABLE public.programme_reports DISABLE TRIGGER report_transition_gate;
  DELETE FROM public.programme_reports WHERE programme_id IN
    (SELECT id FROM public.programmes WHERE name LIKE 'W3EX%');
  ALTER TABLE public.programme_reports ENABLE TRIGGER report_transition_gate;
  -- decided evidence is immutable on every path (NFR-09) — exempt the wipe
  ALTER TABLE public.evidence_items DISABLE TRIGGER evidence_immutable;
  DELETE FROM public.programmes WHERE name LIKE 'W3EX%';
  ALTER TABLE public.evidence_items ENABLE TRIGGER evidence_immutable;
  DELETE FROM public.client_orgs WHERE name LIKE 'W3EX%';
  DELETE FROM public.practices WHERE name LIKE 'W3EX%';
  DELETE FROM public.role_assignments WHERE user_id IN
    (SELECT id FROM public.users WHERE email LIKE '%@w3ex.test');
  DELETE FROM public.users WHERE email LIKE '%@w3ex.test';
  DELETE FROM auth.users WHERE email LIKE '%@w3ex.test';
END $$;
SELECT pg_temp.w3ex_wipe();

-- ---------- seed ----------
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
  ('a3e70000-0000-0000-0000-000000000001'::uuid, 'padmin@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000002'::uuid, 'pl@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000003'::uuid, 'contrib@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000004'::uuid, 'wl@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000005'::uuid, 'badmin@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000006'::uuid, 'ro@w3ex.test'),
  ('a3e70000-0000-0000-0000-000000000007'::uuid, 'ao@w3ex.test')
) AS u(id, email);
INSERT INTO public.users (id, email, full_name)
SELECT id, email, 'W3EX ' || split_part(email, '@', 1)
  FROM auth.users WHERE email LIKE '%@w3ex.test';

INSERT INTO public.practices (id, name) VALUES
  ('b3e70000-0000-0000-0000-00000000000a', 'W3EX Partner A'),
  ('b3e70000-0000-0000-0000-00000000000b', 'W3EX Partner B');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c3e70000-0000-0000-0000-00000000000a', 'b3e70000-0000-0000-0000-00000000000a', 'W3EX Client A'),
  ('c3e70000-0000-0000-0000-00000000000b', 'b3e70000-0000-0000-0000-00000000000b', 'W3EX Client B');
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d3e70000-0000-0000-0000-000000000001', 'c3e70000-0000-0000-0000-00000000000a', 'W3EX P1', DATE '2026-11-02', 20),
  ('d3e70000-0000-0000-0000-000000000002', 'c3e70000-0000-0000-0000-00000000000a', 'W3EX P2', DATE '2026-11-02', 20),
  ('d3e70000-0000-0000-0000-000000000003', 'c3e70000-0000-0000-0000-00000000000b', 'W3EX P3', DATE '2026-11-02', 20);
INSERT INTO public.workstreams (id, programme_id, name) VALUES
  ('03e70000-0000-0000-0000-000000000001', 'd3e70000-0000-0000-0000-000000000001', 'W3EX WS1');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a3e70000-0000-0000-0000-000000000001','partner','partner_admin','partner','b3e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000002','client','programme_lead','programme','d3e70000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000003','client','client_contributor','client','c3e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000004','client','workstream_lead','workstream','03e70000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000005','partner','partner_admin','partner','b3e70000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000006','partner','read_only','partner','b3e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a3e70000-0000-0000-0000-000000000007','client','accountable_officer','client','c3e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL);

-- P1 data: 2 activities (A2 depends on A1), 2 register items, 2 evidence
-- items (one decided + accepted with a minted ref), 1 KPI × 2 actuals,
-- 1 maintenance task instance, 2 reports (issued + draft).
INSERT INTO public.activities (id, programme_id, workstream_id, ref, text, leads,
                               start_week, end_week, status) VALUES
  ('f3e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001','03e70000-0000-0000-0000-000000000001','EX-A1','policy drafted', ARRAY['a3e70000-0000-0000-0000-000000000002']::uuid[],1,4,'Complete'),
  ('f3e70000-0000-0000-0000-000000000002','d3e70000-0000-0000-0000-000000000001',NULL,'EX-A2','agreements signed','{}',1,6,'In progress'),
  ('f3e70000-0000-0000-0000-000000000003','d3e70000-0000-0000-0000-000000000002',NULL,'EX-B1','P2 work','{}',1,4,'In progress'),
  ('f3e70000-0000-0000-0000-000000000004','d3e70000-0000-0000-0000-000000000003',NULL,'EX-C1','P3 work','{}',1,4,'In progress');
INSERT INTO public.activity_deps (activity_id, depends_on_activity_id) VALUES
  ('f3e70000-0000-0000-0000-000000000002','f3e70000-0000-0000-0000-000000000001');

INSERT INTO public.register_items (id, programme_id, ref, finding, priority,
                                   planned_close_week, status, lead) VALUES
  ('93e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001','EX-R1','no privacy policy','High',5,'In progress','a3e70000-0000-0000-0000-000000000002'),
  ('93e70000-0000-0000-0000-000000000002','d3e70000-0000-0000-0000-000000000001','EX-R2','operator clauses','Medium',7,'Not started',NULL),
  ('93e70000-0000-0000-0000-000000000003','d3e70000-0000-0000-0000-000000000003','EX-C1','P3 finding','Low',9,'Not started',NULL);
INSERT INTO public.register_item_activities (register_item_id, activity_id) VALUES
  ('93e70000-0000-0000-0000-000000000001','f3e70000-0000-0000-0000-000000000001');

-- decided + accepted evidence on R1/A1 (ref minted), plus an undecided link item
INSERT INTO public.evidence_items (id, programme_id, activity_id, register_item_id,
                                   file_key, link, uploaded_by, review_stage, outcome, evidence_ref) VALUES
  ('e3e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001',
   'f3e70000-0000-0000-0000-000000000001','93e70000-0000-0000-0000-000000000001',
   'c3e70000-0000-0000-0000-00000000000a/aa11', NULL,
   'a3e70000-0000-0000-0000-000000000002','decided','closes_finding','EV-EXR1-1'),
  ('e3e70000-0000-0000-0000-000000000002','d3e70000-0000-0000-0000-000000000001',
   NULL,'93e70000-0000-0000-0000-000000000002',
   NULL,'https://example.test/doc',
   'a3e70000-0000-0000-0000-000000000003','verification',NULL,NULL);
INSERT INTO public.evidence_reviews (evidence_item_id, stage, reviewer, decision) VALUES
  ('e3e70000-0000-0000-0000-000000000001','accept','a3e70000-0000-0000-0000-000000000007','accepted');

INSERT INTO public.kpis (id, programme_id, name, unit, baseline, target, sort) VALUES
  ('13e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001','W3EX staff trained','%',50,95,1);
INSERT INTO public.kpi_actuals (kpi_id, month, value, evidence_id, entered_by) VALUES
  ('13e70000-0000-0000-0000-000000000001', DATE '2026-10-01', 60, NULL, 'a3e70000-0000-0000-0000-000000000002'),
  ('13e70000-0000-0000-0000-000000000001', DATE '2026-11-01', 72, 'e3e70000-0000-0000-0000-000000000001', 'a3e70000-0000-0000-0000-000000000002');

INSERT INTO public.maintenance_task_templates (id, programme_id, code, task, timing_rule, sort) VALUES
  ('23e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001','EX-MM-01','collect attendance','{"window":"before_month_end","business_day":3}',1);
INSERT INTO public.maintenance_task_instances (task_template_id, period, due_date, status, assignee,
                                               completed_on, evidence_exempt_reason) VALUES
  ('23e70000-0000-0000-0000-000000000001','2026-10', DATE '2026-10-28','Complete','a3e70000-0000-0000-0000-000000000002',
   now(), 'attendance sheet — not evidence-producing (FR-MNT-05)');

INSERT INTO public.programme_reports (id, programme_id, period, reference, status,
                                      version, issued_on, issued_by, sections) VALUES
  ('33e70000-0000-0000-0000-000000000001','d3e70000-0000-0000-0000-000000000001','2026-10','RPT-2026-10-v1','issued',1,now(),'a3e70000-0000-0000-0000-000000000007','{}'),
  ('33e70000-0000-0000-0000-000000000002','d3e70000-0000-0000-0000-000000000001','2026-11',NULL,'draft',1,NULL,NULL,'{}');

-- ---------- 1. row parity + content spot checks (padmin) ----------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000001","role":"authenticated"}';

SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_register_items('d3e70000-0000-0000-0000-000000000001'))
    = (SELECT count(*) FROM public.register_items WHERE programme_id = 'd3e70000-0000-0000-0000-000000000001'),
  '01 register export row parity vs table (P1, 2 rows)');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.export_register_items('d3e70000-0000-0000-0000-000000000001')
          WHERE ref = 'EX-R1' AND linked_activities = 'EX-A1' AND lead = 'W3EX pl'
            AND priority = 'High' AND NOT retired),
  '02 register row carries finding, lead name, linked activity refs');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_activities('d3e70000-0000-0000-0000-000000000001')) = 2
  AND EXISTS (SELECT 1 FROM public.export_activities('d3e70000-0000-0000-0000-000000000001')
              WHERE ref = 'EX-A2' AND depends_on = 'EX-A1')
  AND EXISTS (SELECT 1 FROM public.export_activities('d3e70000-0000-0000-0000-000000000001')
              WHERE ref = 'EX-A1' AND workstream = 'W3EX WS1' AND leads = 'W3EX pl'),
  '03 schedule export: deps, workstream name, lead names resolved');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_evidence_index('d3e70000-0000-0000-0000-000000000001')) = 2
  AND EXISTS (SELECT 1 FROM public.export_evidence_index('d3e70000-0000-0000-0000-000000000001')
              WHERE evidence_ref = 'EV-EXR1-1' AND kind = 'file'
                AND activity_ref = 'EX-A1' AND register_ref = 'EX-R1'
                AND accepted_by = 'W3EX ao' AND accepted_on IS NOT NULL)
  AND EXISTS (SELECT 1 FROM public.export_evidence_index('d3e70000-0000-0000-0000-000000000001')
              WHERE link = 'https://example.test/doc' AND review_stage = 'verification'),
  '04 evidence index: decided ref + acceptance detail + link item');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_kpi_history('d3e70000-0000-0000-0000-000000000001')) = 2
  AND EXISTS (SELECT 1 FROM public.export_kpi_history('d3e70000-0000-0000-0000-000000000001')
              WHERE kpi_name = 'W3EX staff trained' AND month = DATE '2026-11-01'
                AND value = 72 AND evidence_ref = 'EV-EXR1-1' AND entered_by = 'W3EX pl'),
  '05 KPI history: one row per actual, evidence ref resolved');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_report_index('d3e70000-0000-0000-0000-000000000001')) = 2
  AND EXISTS (SELECT 1 FROM public.export_report_index('d3e70000-0000-0000-0000-000000000001')
              WHERE period = '2026-10' AND status = 'issued' AND reference = 'RPT-2026-10-v1'
                AND issued_by = 'W3EX ao' AND is_latest),
  '06 report index: issued row with reference + issuer name');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_maintenance_history('d3e70000-0000-0000-0000-000000000001')) = 1
  AND EXISTS (SELECT 1 FROM public.export_maintenance_history('d3e70000-0000-0000-0000-000000000001')
              WHERE code = 'EX-MM-01' AND period = '2026-10' AND status = 'Complete'
                AND assignee = 'W3EX pl'),
  '07 maintenance history: instance joined to its template code');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_client_pack('c3e70000-0000-0000-0000-00000000000a')) = 3
  AND (SELECT count(*) FROM public.export_client_pack('c3e70000-0000-0000-0000-00000000000a')
        WHERE programme = 'W3EX P2' AND report_period IS NULL) = 1,
  '08 client pack: P1×2 report months + P2 with NULL report columns');

RESET ROLE;
RESET request.jwt.claims;

-- ---------- 2. caller-visible only: scoped and cross-tenant callers ----------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_register_items('d3e70000-0000-0000-0000-000000000001')) = 2,
  '09 programme-scope lead exports own programme');
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_register_items('d3e70000-0000-0000-0000-000000000002')$$,
  '%not found or not visible%', '10 programme-scope lead refused on P2');
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_client_pack('c3e70000-0000-0000-0000-00000000000a')$$,
  '%not found or not visible%', '11 programme-scope caller cannot pull the client pack');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_client_pack('c3e70000-0000-0000-0000-00000000000a')) = 3,
  '12 client-scope contributor pulls the client pack');
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_register_items('d3e70000-0000-0000-0000-000000000003')$$,
  '%not found or not visible%', '13 client A contributor refused on partner-B programme');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_activities('d3e70000-0000-0000-0000-000000000001')) = 2,
  '14 workstream-scope caller: whole-programme schedule (W4-D3 read widening — matches RLS)');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_register_items('d3e70000-0000-0000-0000-000000000001')$$,
  '%not found or not visible%', '15 partner-B admin refused on partner-A programme');
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_client_pack('c3e70000-0000-0000-0000-00000000000a')$$,
  '%not found or not visible%', '16 partner-B admin refused on partner-A client pack');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_register_items('d3e70000-0000-0000-0000-000000000003')) = 1,
  '17 partner-B admin exports own programme (1 row)');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_evidence_index('d3e70000-0000-0000-0000-000000000001')) = 2,
  '18 partner read_only exports the read surface it can see');
RESET ROLE;
RESET request.jwt.claims;

-- ---------- 3. audit extract — admins only (spec §11) ----------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.export_audit_extract('b3e70000-0000-0000-0000-00000000000a')) >= 1,
  '19 partner_admin extracts own partner''s audit trail');
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_audit_extract('b3e70000-0000-0000-0000-00000000000b')$$,
  '%not found or not visible%', '20 partner_admin refused on partner-B audit trail');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_audit_extract('b3e70000-0000-0000-0000-00000000000a')$$,
  '%not found or not visible%', '21 non-admin client role refused the audit extract');
RESET ROLE;
RESET request.jwt.claims;

-- ---------- 4. disclosure audit rows ----------
-- padmin's calls above (checks 01-08, 19) each wrote export.* rows for
-- partner A; scoped/counts live in detail.
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE user_id = 'a3e70000-0000-0000-0000-000000000001'
            AND practice_id = 'b3e70000-0000-0000-0000-00000000000a'
            AND action = 'export.register_items'
            AND detail->>'programme_id' = 'd3e70000-0000-0000-0000-000000000001'
            AND (detail->>'rows')::int = 2),
  '22 audit row: export.register_items with programme scope + row count');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE action = 'export.client_pack'
            AND detail->>'client_org_id' = 'c3e70000-0000-0000-0000-00000000000a'
            AND (detail->>'rows')::int = 3),
  '23 audit row: export.client_pack with client scope + row count');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE action = 'export.audit_extract'
            AND detail->>'practice_id' = 'b3e70000-0000-0000-0000-00000000000a'),
  '24 audit row: the audit extract itself is logged');

-- an export that returns nothing still leaves a row (P2 has no KPIs).
-- Separate statements: the audit INSERT happens inside the export call, so a
-- sibling EXISTS in the same statement can't see it (same-command CID).
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT count(*) AS p2_kpi_rows FROM public.export_kpi_history('d3e70000-0000-0000-0000-000000000002') \g /dev/null
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE user_id = 'a3e70000-0000-0000-0000-000000000001'
            AND action = 'export.kpi_history'
            AND detail->>'programme_id' = 'd3e70000-0000-0000-0000-000000000002'
            AND (detail->>'rows')::int = 0),
  '25 zero-row export still writes its disclosure audit row');
RESET ROLE;
RESET request.jwt.claims;

-- refused callers leave nothing
SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.audit_log
              WHERE user_id = 'a3e70000-0000-0000-0000-000000000005'
                AND action LIKE 'export.%'
                AND detail->>'programme_id' = 'd3e70000-0000-0000-0000-000000000001'),
  '26 partner-B''s refused exports wrote no audit rows on P1');

-- ---------- 5. human-format read is audited too ----------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.export_report_view('33e70000-0000-0000-0000-000000000001');
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE user_id = 'a3e70000-0000-0000-0000-000000000001'
            AND action = 'export.report_view'
            AND detail->>'report_id' = '33e70000-0000-0000-0000-000000000001'),
  '27 report_view audit row for the HTML export');

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.export_report_view('33e70000-0000-0000-0000-000000000001')$$,
  '%not found or not visible%', '28 partner-B refused the report-view audit path');
RESET ROLE;
RESET request.jwt.claims;

-- ---------- 6. surface lockdown ----------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a3e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.export_audit_row('b3e70000-0000-0000-0000-00000000000a','x','{}',0)$$,
  '%permission denied%', '29 audit-writer helper not callable by clients');
SELECT pg_temp.refused(
  $$SELECT public.export_guard_programme('d3e70000-0000-0000-0000-000000000001')$$,
  '%permission denied%', '30 guard helper not callable by clients');
RESET ROLE;
RESET request.jwt.claims;
SET ROLE anon;
SELECT pg_temp.refused(
  $$SELECT * FROM public.export_register_items('d3e70000-0000-0000-0000-000000000001')$$,
  '%permission denied%', '31 anon has no EXECUTE on export RPCs');
RESET ROLE;

-- ---------- teardown ----------
SELECT pg_temp.w3ex_wipe();

DO $$
BEGIN
  RAISE NOTICE 'e2e_exports complete';
END $$;
