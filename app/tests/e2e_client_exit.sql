-- ============================================================================
-- W4-04 (#51) client exit — psql acceptance checks for
-- 20261106000032_client_exit.sql (NFR-14, AT-20): the lifecycle
-- request → export issued → deletion executed → certificate issued, the
-- timed-deletion gate, the authoriser rule, the tombstone + retained set,
-- certificate immutability and cross-tenant refusal.
--
-- SELF-CONTAINED: seeds its own @w4ex.test / 'W4EX%' namespace (two partners,
-- two clients) and never reads or mutates the shared TESTFIX world.
-- Re-runnable: the namespace is wiped first and torn down at the end.
-- Staged rows are written claim-free (service path). JWT callers are
-- simulated with SET ROLE authenticated + request.jwt.claims
-- (e2e_role_assignments.sql pattern).
--
-- Actors (a4e70000-…-000N):
--   U1 padmin   partner_admin, partner A           — manages exit on client A
--   U2 ao       accountable_officer, client A      — client-side authoriser
--   U3 pl       programme_lead, programme P1 scope — NOT an exit authoriser
--   U4 cadmin   client_admin, client A             — client-side authoriser
--   U5 badmin   partner_admin, partner B           — cross-tenant
--   U6 ro       read_only, partner A               — read but not manage
--   U7 consult  partner_consultant, partner A      — consultant matrix row
--   U8 support  platform support, client-scope on A — loses access at exit
--
-- Client A carries a full spread: programme P1 with the engine tree incl.
-- DECIDED evidence and an ISSUED report (the immutability-bypass proof),
-- the stage-pipeline tables, client registers, awareness rows, support
-- access, invites, notification + scan-queue rows.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_client_exit.sql
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

-- exit/certificate tables are RPC-only (no SELECT grant to authenticated);
-- a definer id-lookup lets JWT blocks address rows without widening reads.
CREATE OR REPLACE FUNCTION pg_temp.w4ex_exit(p_client uuid, p_status text DEFAULT NULL)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM public.client_exits
   WHERE client_org_id = p_client
     AND (p_status IS NULL OR status = p_status)
   ORDER BY requested_at DESC LIMIT 1
$$;
CREATE OR REPLACE FUNCTION pg_temp.w4ex_cert(p_client uuid)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT certificate_id FROM public.client_exits
   WHERE client_org_id = p_client AND status = 'certified'
   ORDER BY requested_at DESC LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION pg_temp.w4ex_exit(uuid, text), pg_temp.w4ex_cert(uuid) TO authenticated;

-- ---------- wipe any earlier run ----------
CREATE OR REPLACE FUNCTION pg_temp.w4ex_wipe() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- exits ↔ certs is a two-FK cycle: break exits.certificate_id first, then
  -- certs (immutable by trigger — the wipe suspends USER triggers, same
  -- convention as the fixture wipes), then exits
  UPDATE public.client_exits SET certificate_id = NULL WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%');
  ALTER TABLE public.deletion_certificates DISABLE TRIGGER USER;
  DELETE FROM public.deletion_certificates WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%');
  ALTER TABLE public.deletion_certificates ENABLE TRIGGER USER;
  DELETE FROM public.client_exits WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%');
  DELETE FROM public.billing_events WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%');
  DELETE FROM public.invites WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%');
  DELETE FROM public.notification_events
   WHERE scope->>'client_org_id' IN
         (SELECT id::text FROM public.client_orgs WHERE name LIKE 'W4EX%')
      OR scope->>'practice_id' IN
         (SELECT id::text FROM public.practices WHERE name LIKE 'W4EX%');
  DELETE FROM public.malware_scan_queue WHERE object_key LIKE 'w4ex/%';
  -- decided evidence / issued reports / append-only ledgers refuse deletes;
  -- suspend the named guards for the namespace wipe, exactly like the
  -- exit path itself and the fixture wipes do
  ALTER TABLE public.evidence_items      DISABLE TRIGGER USER;
  ALTER TABLE public.programme_reports   DISABLE TRIGGER USER;
  ALTER TABLE public.decisions           DISABLE TRIGGER USER;
  ALTER TABLE public.raid_status_history DISABLE TRIGGER USER;
  ALTER TABLE public.checklist_item_completions DISABLE TRIGGER USER;
  DELETE FROM public.client_orgs WHERE name LIKE 'W4EX%';
  ALTER TABLE public.evidence_items      ENABLE TRIGGER USER;
  ALTER TABLE public.programme_reports   ENABLE TRIGGER USER;
  ALTER TABLE public.decisions           ENABLE TRIGGER USER;
  ALTER TABLE public.raid_status_history ENABLE TRIGGER USER;
  ALTER TABLE public.checklist_item_completions ENABLE TRIGGER USER;
  DELETE FROM public.audit_log WHERE practice_id IN
    (SELECT id FROM public.practices WHERE name LIKE 'W4EX%')
    OR user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w4ex.test');
  DELETE FROM public.practices WHERE name LIKE 'W4EX%';
  DELETE FROM public.role_assignments WHERE user_id IN
    (SELECT id FROM public.users WHERE email LIKE '%@w4ex.test');
  DELETE FROM public.users WHERE email LIKE '%@w4ex.test';
  DELETE FROM auth.users WHERE email LIKE '%@w4ex.test';
END $$;
SELECT pg_temp.w4ex_wipe();

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
  ('a4e70000-0000-0000-0000-000000000001'::uuid, 'padmin@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000002'::uuid, 'ao@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000003'::uuid, 'pl@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000004'::uuid, 'cadmin@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000005'::uuid, 'badmin@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000006'::uuid, 'ro@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000007'::uuid, 'consult@w4ex.test'),
  ('a4e70000-0000-0000-0000-000000000008'::uuid, 'support@w4ex.test')
) AS u(id, email);
INSERT INTO public.users (id, email, full_name)
SELECT id, email, 'W4EX ' || split_part(email, '@', 1)
  FROM auth.users WHERE email LIKE '%@w4ex.test';

INSERT INTO public.practices (id, name) VALUES
  ('b4e70000-0000-0000-0000-00000000000a', 'W4EX Partner A'),
  ('b4e70000-0000-0000-0000-00000000000b', 'W4EX Partner B');
INSERT INTO public.client_orgs (id, practice_id, name, trading_name) VALUES
  ('c4e70000-0000-0000-0000-00000000000a', 'b4e70000-0000-0000-0000-00000000000a',
   'W4EX Client A', 'W4EX Trading A'),
  ('c4e70000-0000-0000-0000-00000000000b', 'b4e70000-0000-0000-0000-00000000000b',
   'W4EX Client B', NULL);
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d4e70000-0000-0000-0000-000000000001', 'c4e70000-0000-0000-0000-00000000000a', 'W4EX P1', DATE '2026-11-02', 20),
  ('d4e70000-0000-0000-0000-000000000003', 'c4e70000-0000-0000-0000-00000000000b', 'W4EX PB', DATE '2026-11-02', 20);
INSERT INTO public.workstreams (id, programme_id, name) VALUES
  ('04e70000-0000-0000-0000-000000000001', 'd4e70000-0000-0000-0000-000000000001', 'W4EX WS1');
INSERT INTO public.phases (id, programme_id, number, name, start_week, end_week) VALUES
  ('14e70000-0000-0000-0000-000000000001', 'd4e70000-0000-0000-0000-000000000001', 1, 'W4EX phase', 1, 8);

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a4e70000-0000-0000-0000-000000000001','partner','partner_admin','partner','b4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000002','client','accountable_officer','client','c4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000003','client','programme_lead','programme','d4e70000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000004','client','client_admin','client','c4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000005','partner','partner_admin','partner','b4e70000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000006','partner','read_only','partner','b4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000007','partner','partner_consultant','partner','b4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a4e70000-0000-0000-0000-000000000008','platform','support','client','c4e70000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL);

-- programme engine rows on P1 (incl. decided evidence + issued report — the
-- rows whose own triggers forbid deletion)
INSERT INTO public.activities (id, programme_id, workstream_id, ref, text, leads,
                               start_week, end_week, status) VALUES
  ('f4e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','04e70000-0000-0000-0000-000000000001','WX-A1','policy drafted', ARRAY['a4e70000-0000-0000-0000-000000000003']::uuid[],1,4,'Complete'),
  ('f4e70000-0000-0000-0000-000000000002','d4e70000-0000-0000-0000-000000000001',NULL,'WX-A2','agreements signed','{}',1,6,'In progress');
INSERT INTO public.activity_deps (activity_id, depends_on_activity_id) VALUES
  ('f4e70000-0000-0000-0000-000000000002','f4e70000-0000-0000-0000-000000000001');
INSERT INTO public.activity_status_history (activity_id, old_status, new_status, changed_by) VALUES
  ('f4e70000-0000-0000-0000-000000000001','Not started','Complete','a4e70000-0000-0000-0000-000000000003');
INSERT INTO public.register_items (id, programme_id, ref, finding, priority,
                                   planned_close_week, status, lead) VALUES
  ('94e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','WX-R1','no privacy policy','High',5,'In progress','a4e70000-0000-0000-0000-000000000003');
INSERT INTO public.register_item_activities (register_item_id, activity_id) VALUES
  ('94e70000-0000-0000-0000-000000000001','f4e70000-0000-0000-0000-000000000001');
INSERT INTO public.evidence_items (id, programme_id, activity_id, register_item_id,
                                   file_key, link, uploaded_by, review_stage, outcome, evidence_ref) VALUES
  ('e4e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001',
   'f4e70000-0000-0000-0000-000000000001','94e70000-0000-0000-0000-000000000001',
   'w4ex/clientA/ev1.pdf', NULL,
   'a4e70000-0000-0000-0000-000000000003','decided','closes_finding','EV-WXR1-1'),
  ('e4e70000-0000-0000-0000-000000000002','d4e70000-0000-0000-0000-000000000001',
   NULL,'94e70000-0000-0000-0000-000000000001',
   NULL,'https://example.test/doc',
   'a4e70000-0000-0000-0000-000000000003','verification',NULL,NULL);
INSERT INTO public.evidence_reviews (evidence_item_id, stage, reviewer, decision) VALUES
  ('e4e70000-0000-0000-0000-000000000001','accept','a4e70000-0000-0000-0000-000000000002','accepted');
INSERT INTO public.kpis (id, programme_id, name, unit, baseline, target, sort) VALUES
  ('24e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','W4EX staff trained','%',50,95,1);
INSERT INTO public.kpi_actuals (kpi_id, month, value, entered_by) VALUES
  ('24e70000-0000-0000-0000-000000000001', DATE '2026-10-01', 60, 'a4e70000-0000-0000-0000-000000000003');
INSERT INTO public.raid_items (id, programme_id, type, description, status) VALUES
  ('44e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','risk','W4EX register risk','Open');
INSERT INTO public.raid_status_history (raid_item_id, old_status, new_status, changed_by) VALUES
  ('44e70000-0000-0000-0000-000000000001','Open','In progress','a4e70000-0000-0000-0000-000000000001');
INSERT INTO public.decisions (raid_item_id, outcome, decided_by) VALUES
  ('44e70000-0000-0000-0000-000000000001','accepted as residual','a4e70000-0000-0000-0000-000000000002');
INSERT INTO public.maintenance_task_templates (id, programme_id, code, task, timing_rule, sort) VALUES
  ('54e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','WX-MM-01','collect attendance','{"window":"before_month_end","business_day":3}',1);
INSERT INTO public.maintenance_task_instances (task_template_id, period, due_date, status,
                                               completed_on, evidence_exempt_reason) VALUES
  ('54e70000-0000-0000-0000-000000000001','2026-10', DATE '2026-10-28','Complete',
   now(), 'attendance sheet — not evidence-producing (FR-MNT-05)');
INSERT INTO public.checklist_instances (id, programme_id, kind, period) VALUES
  ('64e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','quarterly','2026-Q4');
INSERT INTO public.checklist_item_completions (checklist_id, programme_id, item_key, note, completed_by) VALUES
  ('64e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','wx.i1','done by hand','a4e70000-0000-0000-0000-000000000003');
INSERT INTO public.monthly_snapshots (programme_id, period, snapshot) VALUES
  ('d4e70000-0000-0000-0000-000000000001','2026-10','{"n":1}');
INSERT INTO public.weekly_logs (programme_id, week, blockers) VALUES
  ('d4e70000-0000-0000-0000-000000000001',1,'none');
INSERT INTO public.programme_reports (id, programme_id, period, reference, status,
                                      version, issued_on, issued_by, sections) VALUES
  ('34e70000-0000-0000-0000-000000000001','d4e70000-0000-0000-0000-000000000001','2026-10','WX-RPT-1','issued',1,now(),'a4e70000-0000-0000-0000-000000000002','{}');

-- stage-pipeline + client-register rows on client A
INSERT INTO public.tracks (id, client_org_id, track_kind, current_stage) VALUES
  ('74e70000-0000-0000-0000-000000000001','c4e70000-0000-0000-0000-00000000000a','privacy',3);
INSERT INTO public.stage_transitions (track_id, from_stage, to_stage, actor) VALUES
  ('74e70000-0000-0000-0000-000000000001',0,1,'a4e70000-0000-0000-0000-000000000001');
INSERT INTO public.assessment_sessions (id, client_org_id, title, status) VALUES
  ('84e70000-0000-0000-0000-000000000001','c4e70000-0000-0000-0000-00000000000a','W4EX baseline','complete');
INSERT INTO public.assessment_responses (session_id, question_id, response)
SELECT '84e70000-0000-0000-0000-000000000001', q.id, 'partial'
  FROM public.assessment_questions q ORDER BY q.id LIMIT 1;
INSERT INTO public.assessment_scores (session_id, completion_pct) VALUES
  ('84e70000-0000-0000-0000-000000000001', 100);
INSERT INTO public.assessment_reports (id, client_org_id, framework_key, title)
SELECT 'a4e70000-0000-0000-0000-0000000000a1'::uuid, 'c4e70000-0000-0000-0000-00000000000a'::uuid,
       cp.framework_key, 'W4EX gap report'
  FROM public.content_packs cp ORDER BY cp.id LIMIT 1;
INSERT INTO public.documents (id, client_org_id, original_filename, mime, size,
                              sha256, storage_path, uploaded_by) VALUES
  ('94e70000-0000-0000-0000-0000000000d1','c4e70000-0000-0000-0000-00000000000a',
   'w4ex-policy.pdf','application/pdf',1024,
   'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
   'w4ex/clientA/policy.pdf','a4e70000-0000-0000-0000-000000000001');
INSERT INTO public.document_links (client_org_id, checklist_id, document_id)
SELECT 'c4e70000-0000-0000-0000-00000000000a', c.id,
       '94e70000-0000-0000-0000-0000000000d1'
  FROM public.document_checklists c ORDER BY c.id LIMIT 1;
INSERT INTO public.policies (id, client_org_id, title) VALUES
  ('b4e70000-0000-0000-0000-0000000000a1','c4e70000-0000-0000-0000-00000000000a','W4EX privacy policy');
INSERT INTO public.manuals (id, client_org_id, title) VALUES
  ('b4e70000-0000-0000-0000-0000000000b1','c4e70000-0000-0000-0000-00000000000a','W4EX PIMS manual');
INSERT INTO public.tasks (id, client_org_id, theme, title, priority) VALUES
  ('b4e70000-0000-0000-0000-0000000000c1','c4e70000-0000-0000-0000-00000000000a','Governance','W4EX remediation task','high');
INSERT INTO public.monthly_reports (id, client_org_id, period, title) VALUES
  ('b4e70000-0000-0000-0000-0000000000d1','c4e70000-0000-0000-0000-00000000000a','2026-10','W4EX October report');
INSERT INTO public.operational_records (client_org_id, type, description, reported_at, reported_by) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','breach','W4EX suspected breach',now(),'a4e70000-0000-0000-0000-000000000003');
INSERT INTO public.training_records (client_org_id, person, session, attendance) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','W4EX staff member','W4EX induction',true);
INSERT INTO public.controlled_documents (id, client_org_id, reference, title, version) VALUES
  ('c4e70000-0000-0000-0000-0000000000cd','c4e70000-0000-0000-0000-00000000000a','W4EX-DOC-1','W4EX controlled doc','1.0');
INSERT INTO public.controlled_document_activities (controlled_document_id, activity_id) VALUES
  ('c4e70000-0000-0000-0000-0000000000cd','f4e70000-0000-0000-0000-000000000001');
INSERT INTO public.external_providers (client_org_id, name, kind) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','W4EX IT provider','IT');
INSERT INTO public.designations (client_org_id, role, person, date_designated) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','information_officer','a4e70000-0000-0000-0000-000000000002', CURRENT_DATE);
INSERT INTO public.awareness_cohorts (id, client_org_id, framework_key, content_pack_id,
                                     department, status)
SELECT 'd4e70000-0000-0000-0000-0000000000c1'::uuid,
       'c4e70000-0000-0000-0000-00000000000a'::uuid,
       cp.framework_key, cp.id, 'All staff', 'complete'
  FROM public.content_packs cp
 WHERE EXISTS (SELECT 1 FROM public.awareness_questions aq
                WHERE aq.content_pack_id = cp.id)
 ORDER BY cp.id LIMIT 1;
INSERT INTO public.awareness_respondents (id, cohort_id, respondent_no)
SELECT 'd4e70000-0000-0000-0000-0000000000c2', 'd4e70000-0000-0000-0000-0000000000c1', 1
 WHERE EXISTS (SELECT 1 FROM public.awareness_cohorts
                WHERE id = 'd4e70000-0000-0000-0000-0000000000c1');
INSERT INTO public.awareness_responses (respondent_id, question_id, answer)
SELECT 'd4e70000-0000-0000-0000-0000000000c2', aq.id, 'yes'
  FROM public.awareness_questions aq
  JOIN public.awareness_cohorts ac ON ac.content_pack_id = aq.content_pack_id
 WHERE ac.id = 'd4e70000-0000-0000-0000-0000000000c1'
 ORDER BY aq.id LIMIT 1;
INSERT INTO public.consultant_assignments (user_id, client_org_id) VALUES
  ('a4e70000-0000-0000-0000-000000000007','c4e70000-0000-0000-0000-00000000000a');
INSERT INTO public.support_access_requests (client_org_id, requested_by, reason, expires_at) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','a4e70000-0000-0000-0000-000000000008','W4EX help','2027-01-01');
INSERT INTO public.support_access_grants (client_org_id, securepath_user_id, reason,
                                          approved_by, expires_at) VALUES
  ('c4e70000-0000-0000-0000-00000000000a','a4e70000-0000-0000-0000-000000000008','W4EX help',
   'a4e70000-0000-0000-0000-000000000002','2027-01-01');
INSERT INTO public.invites (practice_id, email, role, client_org_id, invited_by) VALUES
  ('b4e70000-0000-0000-0000-00000000000a','newbie@w4ex.test','client_admin',
   'c4e70000-0000-0000-0000-00000000000a','a4e70000-0000-0000-0000-000000000001');
INSERT INTO public.notification_events (kind, scope, payload) VALUES
  ('breach_reported','{"client_org_id":"c4e70000-0000-0000-0000-00000000000a","programme_id":"d4e70000-0000-0000-0000-000000000001"}','{"subject":"W4EX"}');
-- malware_scan_queue rows for E1/D1 are auto-enqueued by the W4-03 intake
-- triggers — no manual seed needed; the exit must purge them by subject id.
INSERT INTO public.billing_events (practice_id, client_org_id, event_type, detail) VALUES
  ('b4e70000-0000-0000-0000-00000000000a','c4e70000-0000-0000-0000-00000000000a','instance.created','{"name":"W4EX Client A"}');

-- ============================================================================
-- 1. request + authorisation
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  public.request_client_exit('c4e70000-0000-0000-0000-00000000000a',
                             'W4EX contract end', 30) IS NOT NULL,
  '01 partner_admin opens an exit (30-day retention)');
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND status = 'requested'
            AND requested_by = 'a4e70000-0000-0000-0000-000000000001'
            AND retention_days = 30
            AND deletion_due_on = CURRENT_DATE + 30),
  '02 exit row: requested, due = today + 30, authoriser recorded');

-- a second open request on the same client is refused
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.request_client_exit('c4e70000-0000-0000-0000-00000000000a')$$,
  '%open exit already exists%', '03 second open exit refused');
RESET ROLE;
RESET request.jwt.claims;

-- programme-scope lead is not an exit authoriser (and is not even a
-- client-level reader — allowed_client_orgs carries no programme scopes)
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.request_client_exit('c4e70000-0000-0000-0000-00000000000a')$$,
  '%not found or not visible%', '04 programme-scope lead cannot authorise exit');
RESET ROLE;
RESET request.jwt.claims;

-- partner read_only can see but not authorise
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.request_client_exit('c4e70000-0000-0000-0000-00000000000a')$$,
  '%must be authorised%', '05 partner read_only cannot authorise exit');
RESET ROLE;
RESET request.jwt.claims;

-- partner B cannot touch partner A's exit (invisible, not just unauthorised)
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.request_client_exit('c4e70000-0000-0000-0000-00000000000a')$$,
  '%not found or not visible%', '06 partner-B admin refused on partner-A client');
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- 2. export + timed deletion gate
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM (
     SELECT public.issue_exit_export(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','requested')) AS payload) s
   WHERE jsonb_array_length(payload -> 'sections' -> 'programmes') = 1
     AND jsonb_array_length(payload -> 'sections' -> 'evidence_items') = 2
     AND jsonb_array_length(payload -> 'sections' -> 'documents') = 1
     AND payload -> 'sections' -> 'awareness_respondents' IS NULL) = 1,
  '07 full export: programmes+evidence+documents sections; awareness answers excluded (NFR-15)');
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND status = 'export_issued'
            AND export_manifest ->> 'sha256' ~ '^[0-9a-f]{64}$'
            AND (export_manifest ->> 'total_rows')::int > 20),
  '08 export_issued: manifest keeps counts + sha256 + size');
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE practice_id = 'b4e70000-0000-0000-0000-00000000000a'
            AND action = 'export.client_exit_export'),
  '09 disclosure audit row for the exit export');

-- deletion before the configurable period elapses is refused
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.execute_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','export_issued'))$$,
  '%retention period has not elapsed%', '10 deletion refused inside the 30-day window');
RESET ROLE;
RESET request.jwt.claims;

-- cancel is the pre-delete hold path
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.cancel_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','export_issued'));
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND status = 'cancelled'
            AND cancelled_by = 'a4e70000-0000-0000-0000-000000000001'),
  '11 partner_admin cancels the open exit');

-- client-side authoriser: the accountable officer opens a 0-retention exit
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
  public.request_client_exit('c4e70000-0000-0000-0000-00000000000a',
                             'W4EX immediate exit', 0) IS NOT NULL,
  '12 accountable_officer opens an exit (retention 0 = due today)');
RESET ROLE;
RESET request.jwt.claims;

-- deletion without an export is refused even though the period elapsed
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.execute_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','requested'))$$,
  '%export must be issued%', '13 AT-20 order: export before deletion');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM (
     SELECT public.issue_exit_export(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','requested')) AS payload) s
   WHERE payload ->> 'export' = 'client_exit_full') = 1,
  '14 accountable_officer issues the export');
RESET ROLE;
RESET request.jwt.claims;

-- ============================================================================
-- 3. execute the deletion (retention 0 → due today)
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT public.execute_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','export_issued'));
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND status = 'deleted'
            AND deleted_by = 'a4e70000-0000-0000-0000-000000000001'
            AND deleted_at IS NOT NULL),
  '15 exit row: deleted, executor + timestamp recorded');

SELECT pg_temp.t(
  (SELECT coalesce(sum(c.n),0) FROM (
     SELECT count(*) AS n FROM public.programmes         WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.activities        WHERE programme_id = 'd4e70000-0000-0000-0000-000000000001'
     UNION ALL SELECT count(*) FROM public.register_items    WHERE programme_id = 'd4e70000-0000-0000-0000-000000000001'
     UNION ALL SELECT count(*) FROM public.evidence_items    WHERE programme_id = 'd4e70000-0000-0000-0000-000000000001'
     UNION ALL SELECT count(*) FROM public.programme_reports WHERE programme_id = 'd4e70000-0000-0000-0000-000000000001'
     UNION ALL SELECT count(*) FROM public.tracks            WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.documents         WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.policies          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.tasks             WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.assessment_sessions WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.operational_records WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.awareness_cohorts   WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
     UNION ALL SELECT count(*) FROM public.designations        WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
  ) c) = 0,
  '16 client data gone: programmes, decided evidence, issued reports, pipeline, registers');

SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.decisions
              WHERE raid_item_id = '44e70000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM public.raid_status_history
                  WHERE raid_item_id = '44e70000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM public.raid_items WHERE id = '44e70000-0000-0000-0000-000000000001'),
  '17 append-only ledgers (decisions, raid history) deleted despite their guards');

SELECT pg_temp.t(
  NOT EXISTS (SELECT 1 FROM public.role_assignments
              WHERE (scope_type = 'client' AND scope_id = 'c4e70000-0000-0000-0000-00000000000a')
                 OR (scope_type = 'programme' AND scope_id = 'd4e70000-0000-0000-0000-000000000001'))
  AND NOT EXISTS (SELECT 1 FROM public.invites
                  WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a')
  AND NOT EXISTS (SELECT 1 FROM public.consultant_assignments
                  WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a')
  AND NOT EXISTS (SELECT 1 FROM public.support_access_grants
                  WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a')
  AND NOT EXISTS (SELECT 1 FROM public.notification_events
                  WHERE scope->>'client_org_id' = 'c4e70000-0000-0000-0000-00000000000a')
  AND NOT EXISTS (SELECT 1 FROM public.malware_scan_queue
                  WHERE object_key LIKE 'w4ex/clientA/%'),
  '18 access + housekeeping gone: assignments, invites, grants, outbox, scan queue');

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_orgs
          WHERE id = 'c4e70000-0000-0000-0000-00000000000a'
            AND exited_at IS NOT NULL AND name = 'W4EX Client A'),
  '19 client_orgs tombstone retained (exited_at set, identity kept)');

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.billing_events
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND event_type = 'instance.deleted')
  AND EXISTS (SELECT 1 FROM public.billing_events
              WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
                AND event_type = 'instance.created')
  AND EXISTS (SELECT 1 FROM public.audit_log
              WHERE action = 'client_exit.deleted'
                AND detail->>'client_org_id' = 'c4e70000-0000-0000-0000-00000000000a'),
  '20 retained set: billing ledger + audit trail intact incl. the new events');

-- ============================================================================
-- 4. certificate
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  public.issue_deletion_certificate(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','deleted')) IS NOT NULL,
  '21 partner_admin issues the deletion certificate');
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits e
          JOIN public.deletion_certificates c ON c.id = e.certificate_id
          WHERE e.client_org_id = 'c4e70000-0000-0000-0000-00000000000a'
            AND e.status = 'certified'
            AND c.certificate_no LIKE 'DEL-%'
            AND c.client_name = 'W4EX Trading A'
            AND c.requested_by = 'a4e70000-0000-0000-0000-000000000002'
            AND c.deleted_by   = 'a4e70000-0000-0000-0000-000000000001'
            AND c.issued_by    = 'a4e70000-0000-0000-0000-000000000001'
            AND (c.scope_counts ->> 'programmes')::int = 1
            AND (c.scope_counts ->> 'evidence_items')::int = 2
            AND c.retention_days = 0
            AND c.export_sha256 ~ '^[0-9a-f]{64}$'
            AND c.storage_keys @> '["w4ex/clientA/ev1.pdf"]'
            AND c.retained ? 'audit_events'),
  '22 certificate: counts, authoriser chain, storage purge list, retained set');

-- idempotent re-issue returns the same certificate
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  public.issue_deletion_certificate(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','certified'))
    = pg_temp.w4ex_cert('c4e70000-0000-0000-0000-00000000000a'),
  '23 re-issuing a certified exit is idempotent');
RESET ROLE;
RESET request.jwt.claims;

SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_log
          WHERE action = 'client_exit.certified'
            AND detail->>'client_org_id' = 'c4e70000-0000-0000-0000-00000000000a'),
  '24 audit row for certificate issue');

-- the issued artefact is immutable (NFR-09 — corrections are new versions)
SELECT pg_temp.refused(
  $$UPDATE public.deletion_certificates SET client_name = 'x'
     WHERE practice_id = 'b4e70000-0000-0000-0000-00000000000a'$$,
  '%immutable%', '25 certificate UPDATE refused (immutable artefact)');
SELECT pg_temp.refused(
  $$DELETE FROM public.deletion_certificates
     WHERE practice_id = 'b4e70000-0000-0000-0000-00000000000a'$$,
  '%immutable%', '26 certificate DELETE refused (immutable artefact)');

-- ============================================================================
-- 5. reads + cross-tenant negatives
-- ============================================================================
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.get_deletion_certificate(
     pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','certified'))) = 1,
  '27 partner_admin reads the certificate');
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_client_exits('c4e70000-0000-0000-0000-00000000000a')) = 2,
  '28 list shows both exits on client A (cancelled + certified)');
RESET ROLE;
RESET request.jwt.claims;

SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_client_exits('c4e70000-0000-0000-0000-00000000000a')) = 0,
  '29 partner-B admin sees nothing of partner-A exits');
SELECT pg_temp.refused(
  $$SELECT * FROM public.get_deletion_certificate(
      pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','certified'))$$,
  '%not found or not visible%', '30 partner-B admin refused the certificate');
RESET ROLE;
RESET request.jwt.claims;

-- read_only keeps the read surface
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000006","role":"authenticated"}';
SELECT pg_temp.t(
  (SELECT count(*) FROM public.list_client_exits('c4e70000-0000-0000-0000-00000000000a')) = 2,
  '31 partner read_only reads the exit ledger');
RESET ROLE;
RESET request.jwt.claims;

-- a cancelled exit cannot be exported
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.refused(
  $$SELECT public.issue_exit_export(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000a','cancelled'))$$,
  '%can only be issued before deletion%', '32 cancelled exit cannot be re-exported');
-- nothing can be re-requested on a tombstoned client
SELECT pg_temp.refused(
  $$SELECT public.request_client_exit('c4e70000-0000-0000-0000-00000000000a')$$,
  '%already exited%', '33 exited client refuses a fresh exit request');
RESET ROLE;
RESET request.jwt.claims;

-- partner B flow: request works, execute without export refused, then cancel
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4e70000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT pg_temp.t(
  public.request_client_exit('c4e70000-0000-0000-0000-00000000000b', NULL, 14) IS NOT NULL,
  '34 partner-B admin opens own exit (14-day retention)');
SELECT pg_temp.refused(
  $$SELECT public.execute_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000b','requested'))$$,
  '%export must be issued%', '35 partner-B execute refused without export');
SELECT public.cancel_client_exit(pg_temp.w4ex_exit('c4e70000-0000-0000-0000-00000000000b','requested'));
RESET ROLE;
RESET request.jwt.claims;
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.client_exits
          WHERE client_org_id = 'c4e70000-0000-0000-0000-00000000000b'
            AND status = 'cancelled'),
  '36 partner-B admin cancels own exit');

-- partner B data untouched by partner A's exit
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.programmes
          WHERE id = 'd4e70000-0000-0000-0000-000000000003'
            AND client_org_id = 'c4e70000-0000-0000-0000-00000000000b'),
  '37 partner-B programme untouched by partner-A exit');

-- field-level audit captured the deletions (NFR-08 net stayed live)
SELECT pg_temp.t(
  EXISTS (SELECT 1 FROM public.audit_events
          WHERE table_name = 'programmes' AND action = 'delete'
            AND client_org_id = 'c4e70000-0000-0000-0000-00000000000a'),
  '38 audit_events captured the deleted rows (NFR-08)');

-- ---------- teardown ----------
SELECT pg_temp.w4ex_wipe();
