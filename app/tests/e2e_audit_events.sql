-- ============================================================================
-- W4-06 field-level audit — psql acceptance checks for
-- 20261106000026_audit_events.sql (audit_events table, audit_capture +
-- audit_capture_truncate triggers on every tenant table,
-- platform_audit_extract).
--
-- Self-contained (e2e_platform_admin.sql style): builds its own @w406.test
-- users, 'W406%' practice/client/programme fixtures. JWT callers simulated
-- via SET ROLE authenticated + request.jwt.claims inside BEGIN … ROLLBACK
-- blocks; reads of audit_events switch back with RESET ROLE inside the same
-- transaction (supabase_admin is superuser — RLS bypass).
--
-- Covers: trigger coverage on all 58 tenant tables (and absence on excluded
-- samples); insert/delete whole-row events and per-column update events;
-- actor capture for user-JWT, service_role-JWT and claims-less service
-- writes; tenant resolution for self_* / chain (1-, 2-, 3-hop) / ra / user
-- modes; composite-PK row_id; AT-21 (no user — including a platform admin —
-- can see, edit or delete audit rows; TRUNCATE is permission-denied);
-- platform_audit_extract guard (platform_admin only) + filters.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_audit_events.sql
-- ============================================================================
\set QUIET on
\pset pager off
\pset tuples_only on

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

-- ---------- wipe own namespace (re-runnable) ----------
CREATE OR REPLACE FUNCTION pg_temp.w406_wipe() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.audit_events
   WHERE row_id LIKE '%4060000%' OR actor LIKE '%4060000%'
      OR old_value::text LIKE '%4060000%' OR new_value::text LIKE '%4060000%'
      OR old_value::text LIKE '%w406%' OR new_value::text LIKE '%w406%';
  DELETE FROM public.notification_preferences
   WHERE user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w406.test');
  DELETE FROM public.consultant_assignments
   WHERE client_org_id IN (SELECT id FROM public.client_orgs WHERE name LIKE 'W406%')
      OR user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w406.test');
  EXECUTE 'ALTER TABLE public.decisions DISABLE TRIGGER decisions_append_only';
  DELETE FROM public.decisions
   WHERE raid_item_id IN (SELECT id FROM public.raid_items WHERE description LIKE 'W406%');
  EXECUTE 'ALTER TABLE public.decisions ENABLE TRIGGER decisions_append_only';
  DELETE FROM public.raid_items         WHERE description LIKE 'W406%';
  DELETE FROM public.activities         WHERE ref LIKE 'W406%';
  DELETE FROM public.external_providers WHERE name LIKE 'W406%';
  DELETE FROM public.role_assignments
   WHERE user_id IN (SELECT id FROM public.users WHERE email LIKE '%@w406.test');
  DELETE FROM public.programmes         WHERE name LIKE 'W406%';
  DELETE FROM public.client_orgs        WHERE name LIKE 'W406%';
  DELETE FROM public.practices          WHERE name LIKE 'W406%';
  DELETE FROM public.users              WHERE email LIKE '%@w406.test';
  DELETE FROM auth.users                WHERE email LIKE '%@w406.test';
END $$;
SELECT pg_temp.w406_wipe();

-- ---------- fixtures (claims-less service writes — they also prove the
-- service actor path: every row below lands in audit_events as 'service') --
INSERT INTO auth.users (id, instance_id, email, encrypted_password, aud, role,
    email_confirmed_at, created_at, updated_at, confirmation_token,
    email_change, email_change_token_new, email_change_token_current,
    recovery_token, reauthentication_token, phone_change, phone_change_token,
    raw_app_meta_data, raw_user_meta_data)
SELECT u.id, '00000000-0000-0000-0000-000000000000', u.email,
    crypt('x', gen_salt('bf')), 'authenticated', 'authenticated',
    now(), now(), now(), '',
    '', '', '',
    '', '', '', '',
    '{"provider":"email","providers":["email"]}', '{}'
FROM (VALUES
  ('a4060000-0000-0000-0000-000000000001'::uuid, 'padmin@w406.test'),
  ('a4060000-0000-0000-0000-000000000002'::uuid, 'support@w406.test'),
  ('a4060000-0000-0000-0000-000000000003'::uuid, 'partneradmin@w406.test'),
  ('a4060000-0000-0000-0000-000000000004'::uuid, 'nobody@w406.test')
) AS u(id, email);
INSERT INTO public.users (id, email)
  SELECT id, email FROM auth.users WHERE email LIKE '%@w406.test';

INSERT INTO public.practices (id, name, type, country, subdomain) VALUES
  ('b4060000-0000-0000-0000-000000000001', 'W406 Audit Practice', 'msp', 'ZA', 'w406-audit');
INSERT INTO public.client_orgs (id, practice_id, name) VALUES
  ('c4060000-0000-0000-0000-000000000001', 'b4060000-0000-0000-0000-000000000001', 'W406 Client A');
INSERT INTO public.programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d4060000-0000-0000-0000-000000000001', 'c4060000-0000-0000-0000-000000000001',
   'W406 Programme', DATE '2026-11-02', 10);
INSERT INTO public.raid_items (id, programme_id, type, description) VALUES
  ('e4060000-0000-0000-0000-000000000001', 'd4060000-0000-0000-0000-000000000001',
   'risk', 'W406 risk seed');

INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id) VALUES
  ('a4060000-0000-0000-0000-000000000001','platform','platform_admin','partner',NULL),
  ('a4060000-0000-0000-0000-000000000002','platform','support','partner',NULL),
  ('a4060000-0000-0000-0000-000000000003','partner','partner_admin','partner',
   'b4060000-0000-0000-0000-000000000001');

-- ---------- 1. coverage: every tenant table carries both triggers ----------
SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM (VALUES
      ('practices'),('client_orgs'),('users'),('consultant_assignments'),
      ('role_assignments'),('notification_preferences'),('invites'),
      ('billing_events'),('approvals'),('stage_transitions'),
      ('assessment_sessions'),('assessment_responses'),('assessment_scores'),
      ('assessment_reports'),('tracks'),('documents'),('document_links'),
      ('policies'),('manuals'),('tasks'),('monthly_reports'),
      ('awareness_cohorts'),('designations'),('support_access_grants'),
      ('support_access_requests'),('licences'),('content_packs'),
      ('programme_templates'),('programme_template_versions'),('import_runs'),
      ('programmes'),('phases'),('workstreams'),('activities'),
      ('register_items'),('evidence_items'),('evidence_offers'),
      ('weekly_logs'),('kpis'),('raid_items'),('maintenance_task_templates'),
      ('checklist_instances'),('checklist_item_completions'),
      ('monthly_snapshots'),('programme_reports'),('operational_records'),
      ('training_records'),('controlled_documents'),('external_providers'),
      ('activity_deps'),('activity_status_history'),
      ('register_item_activities'),('controlled_document_activities'),
      ('evidence_reviews'),('kpi_actuals'),('raid_status_history'),
      ('decisions'),('maintenance_task_instances')
    ) AS need(t)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_trigger tg
        JOIN pg_class c  ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = need.t
         AND tg.tgname = 'audit_events_trg' AND NOT tg.tgisinternal)
       OR NOT EXISTS (
        SELECT 1 FROM pg_trigger tg
        JOIN pg_class c  ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = need.t
         AND tg.tgname = 'audit_events_trunc_trg' AND NOT tg.tgisinternal)
  ), '01 all 58 tenant tables carry row + truncate audit triggers');

SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM pg_trigger tg
    JOIN pg_class c  ON c.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND tg.tgname LIKE 'audit_events%'
     AND c.relname IN ('audit_events','audit_log','job_runs','scheduled_jobs',
                       'import_rows','notification_recipients',
                       'notification_events','notifications',
                       'awareness_responses','awareness_respondents',
                       'assessment_questions','frameworks')
  ), '02 excluded tables (ledgers, fan-out, churn, NFR-15, content) untriggered');

-- ---------- 2. insert event: whole row, service actor, tenant resolved ----
INSERT INTO public.external_providers (id, client_org_id, name) VALUES
  ('f4060000-0000-0000-0000-000000000001',
   'c4060000-0000-0000-0000-000000000001', 'W406 Provider One');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='external_providers' AND action='insert'
      AND row_id='id=f4060000-0000-0000-0000-000000000001'
      AND column_name='(row)' AND old_value IS NULL
      AND new_value->>'name'='W406 Provider One'
      AND actor='service' AND actor_id IS NULL
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '03 insert: whole-row event, actor=service, client+practice resolved');

-- ---------- 3. authenticated caller captured through the RLS path ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000003","role":"authenticated"}';
INSERT INTO public.external_providers (client_org_id, name) VALUES
  ('c4060000-0000-0000-0000-000000000001', 'W406 Provider Two');
RESET ROLE;
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events e
    JOIN public.external_providers p ON e.row_id = 'id=' || p.id::text
    WHERE p.name='W406 Provider Two'
      AND e.action='insert' AND e.actor_id='a4060000-0000-0000-0000-000000000003'
      AND e.actor='a4060000-0000-0000-0000-000000000003'
      AND e.client_org_id='c4060000-0000-0000-0000-000000000001'
      AND e.practice_id='b4060000-0000-0000-0000-000000000001'),
    '04 authenticated insert: actor = caller uid, tenant resolved');
ROLLBACK;

-- ---------- 4. update = one event per changed column ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000003","role":"authenticated"}';
UPDATE public.external_providers SET name='W406 Provider One X', active=false
 WHERE id='f4060000-0000-0000-0000-000000000001';
RESET ROLE;
SELECT pg_temp.t(
    (SELECT count(*) FROM public.audit_events
      WHERE table_name='external_providers' AND action='update'
        AND row_id='id=f4060000-0000-0000-0000-000000000001') = 2
    AND EXISTS (SELECT 1 FROM public.audit_events
      WHERE table_name='external_providers' AND action='update'
        AND row_id='id=f4060000-0000-0000-0000-000000000001'
        AND column_name='name'
        AND old_value='"W406 Provider One"'::jsonb
        AND new_value='"W406 Provider One X"'::jsonb)
    AND EXISTS (SELECT 1 FROM public.audit_events
      WHERE table_name='external_providers' AND action='update'
        AND row_id='id=f4060000-0000-0000-0000-000000000001'
        AND column_name='active' AND old_value='true'::jsonb
        AND new_value='false'::jsonb
        AND actor_id='a4060000-0000-0000-0000-000000000003'),
    '05 update: one event per changed column with old/new values');
ROLLBACK;

-- ---------- 5. no-op update emits nothing ----------
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000003","role":"authenticated"}';
UPDATE public.external_providers SET name=name
 WHERE id='f4060000-0000-0000-0000-000000000001';
RESET ROLE;
SELECT pg_temp.t(NOT EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='external_providers' AND action='update'
      AND row_id='id=f4060000-0000-0000-0000-000000000001'),
    '06 no-op update emits no audit events');
ROLLBACK;

-- ---------- 6. service_role JWT claims → actor 'service' ----------
BEGIN;
SET request.jwt.claims = '{"role":"service_role"}';
INSERT INTO public.external_providers (id, client_org_id, name) VALUES
  ('f4060000-0000-0000-0000-000000000002',
   'c4060000-0000-0000-0000-000000000001', 'W406 Provider Svc');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='external_providers' AND action='insert'
      AND row_id='id=f4060000-0000-0000-0000-000000000002'
      AND actor='service' AND actor_id IS NULL),
    '07 service_role-JWT write records actor=service');
ROLLBACK;

-- ---------- 7. delete event ----------
DELETE FROM public.external_providers
 WHERE id='f4060000-0000-0000-0000-000000000001';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='external_providers' AND action='delete'
      AND row_id='id=f4060000-0000-0000-0000-000000000001'
      AND column_name='(row)' AND new_value IS NULL
      AND old_value->>'name' LIKE 'W406 Provider One%'),
    '08 delete: single whole-row event preserving old value');

-- ---------- 8. composite pk row_id ----------
INSERT INTO public.consultant_assignments (user_id, client_org_id) VALUES
  ('a4060000-0000-0000-0000-000000000003', 'c4060000-0000-0000-0000-000000000001');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='consultant_assignments' AND action='insert'
      AND row_id LIKE '%user_id=a4060000-0000-0000-0000-000000000003%'
      AND row_id LIKE '%client_org_id=c4060000-0000-0000-0000-000000000001%'
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '09 composite pk rendered in row_id; tenant resolved via client_orgs hop');

-- ---------- 9. chain resolution: 1 fk hop + client_orgs terminal ----------
INSERT INTO public.activities (id, programme_id, ref, text, start_week, end_week)
VALUES ('a4060000-0000-0000-0000-0000000000aa',
        'd4060000-0000-0000-0000-000000000001', 'W406-A1', 'W406 activity', 1, 2);
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='activities' AND action='insert'
      AND row_id='id=a4060000-0000-0000-0000-0000000000aa'
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '10 programme-keyed row resolves client+practice via 2-hop chain');

-- ---------- 10. chain resolution: grandchild (3 hops) ----------
INSERT INTO public.decisions (id, raid_item_id, outcome, decided_by) VALUES
  ('a4060000-0000-0000-0000-0000000000bb',
   'e4060000-0000-0000-0000-000000000001', 'W406 decision outcome',
   'a4060000-0000-0000-0000-000000000003');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='decisions' AND action='insert'
      AND row_id='id=a4060000-0000-0000-0000-0000000000bb'
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '11 raid grandchild resolves tenant via 3-hop chain');

-- ---------- 11. 'ra' mode: role_assignments' own polymorphic scope ----------
INSERT INTO public.role_assignments (user_id, level, role, scope_type, scope_id)
VALUES ('a4060000-0000-0000-0000-000000000004','client','client_admin','client',
        'c4060000-0000-0000-0000-000000000001');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='role_assignments' AND action='insert'
      AND new_value->>'scope_id'='c4060000-0000-0000-0000-000000000001'
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '12 role_assignments client-scope row tagged to client+practice');
DELETE FROM public.role_assignments
 WHERE user_id='a4060000-0000-0000-0000-000000000004';

-- ---------- 12. 'user' / self_practice / self_client modes ----------
UPDATE public.users SET full_name='W406 Partner Admin'
 WHERE id='a4060000-0000-0000-0000-000000000003';
UPDATE public.practices SET name='W406 Audit Practice X'
 WHERE id='b4060000-0000-0000-0000-000000000001';
UPDATE public.client_orgs SET name='W406 Client A X'
 WHERE id='c4060000-0000-0000-0000-000000000001';
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='users' AND action='update' AND column_name='full_name'
      AND row_id='id=a4060000-0000-0000-0000-000000000003'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '13 user-mode: users row tagged to the user''s practice');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='practices' AND action='update' AND column_name='name'
      AND row_id='id=b4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'
      AND client_org_id IS NULL),
    '14 self_practice mode: practices row tagged to itself');
SELECT pg_temp.t(EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE table_name='client_orgs' AND action='update' AND column_name='name'
      AND row_id='id=c4060000-0000-0000-0000-000000000001'
      AND client_org_id='c4060000-0000-0000-0000-000000000001'
      AND practice_id='b4060000-0000-0000-0000-000000000001'),
    '15 self_client mode: client_orgs row tagged to itself + practice');

-- ---------- 13. AT-21: no app user can see or tamper with audit_events ----
-- Counts denied-or-ineffectual ops out of 4 (SELECT, UPDATE, DELETE,
-- TRUNCATE). REVOKE ALL makes them privilege errors; RLS would make any
-- survivor touch 0 rows. Either way the audit trail is untouchable.
CREATE OR REPLACE FUNCTION pg_temp.w406_tamper() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE n int := 0; c int;
BEGIN
  BEGIN PERFORM count(*) FROM public.audit_events; n := n + 0;  -- readable = bad
        GET DIAGNOSTICS c = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN n := n + 1;
  END;
  BEGIN
    UPDATE public.audit_events SET actor = 'tampered' WHERE true;
    GET DIAGNOSTICS c = ROW_COUNT;
    IF c = 0 THEN n := n + 1; END IF;
  EXCEPTION WHEN OTHERS THEN n := n + 1;
  END;
  BEGIN
    DELETE FROM public.audit_events WHERE true;
    GET DIAGNOSTICS c = ROW_COUNT;
    IF c = 0 THEN n := n + 1; END IF;
  EXCEPTION WHEN OTHERS THEN n := n + 1;
  END;
  BEGIN
    EXECUTE 'TRUNCATE public.audit_events';
  EXCEPTION WHEN OTHERS THEN n := n + 1;
  END;
  RETURN n;
END $$;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w406_tamper() = 4,
    '16 AT-21: tenant user cannot select/update/delete/truncate audit_events');
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w406_tamper() = 4,
    '17 AT-21: even a platform_admin JWT gets no direct audit_events access');
RESET ROLE;
ROLLBACK;

-- ---------- 14. platform_audit_extract: guard + filters ----------
CREATE OR REPLACE FUNCTION pg_temp.w406_extract_denied() RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN PERFORM * FROM public.platform_audit_extract(); RETURN false;
  EXCEPTION WHEN OTHERS THEN RETURN true; END;
END $$;
BEGIN;
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w406_extract_denied(), '18 extract denied: no roles');
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w406_extract_denied(), '19 extract denied: partner_admin');
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT pg_temp.t(pg_temp.w406_extract_denied(), '20 extract denied: platform support');
SET request.jwt.claims = '{"sub":"a4060000-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT pg_temp.t(
    (SELECT count(*) FROM public.platform_audit_extract(
        p_client_org_id := 'c4060000-0000-0000-0000-000000000001',
        p_table_name    := 'external_providers')) >= 2
    AND NOT EXISTS (SELECT 1 FROM public.platform_audit_extract(
        p_client_org_id := 'c4060000-0000-0000-0000-000000000001',
        p_table_name    := 'external_providers') e
        WHERE e.client_org_id <> 'c4060000-0000-0000-0000-000000000001'
           OR e.table_name <> 'external_providers'),
    '21 extract: platform_admin pulls tenant+table filtered events');
SELECT pg_temp.t(
    (SELECT count(*) FROM public.platform_audit_extract(
        p_client_org_id := 'c4060000-0000-0000-0000-000000000001',
        p_table_name    := 'not_a_table')) = 0
    AND (SELECT count(*) FROM public.platform_audit_extract(
        p_client_org_id := 'c4060000-0000-0000-0000-000000000001',
        p_from := now() + interval '1 day')) = 0
    AND (SELECT count(*) FROM public.platform_audit_extract(
        p_client_org_id := 'c4060000-0000-0000-0000-000000000001',
        p_to := timestamptz '2000-01-01')) = 0,
    '22 extract: table and period filters bound correctly');
RESET ROLE;
ROLLBACK;

-- anon gets no EXECUTE at all
BEGIN;
SET ROLE anon;
SELECT pg_temp.t(pg_temp.w406_extract_denied(), '23 extract denied: anon');
RESET ROLE;
ROLLBACK;

-- ---------- teardown ----------
SELECT pg_temp.w406_wipe();
