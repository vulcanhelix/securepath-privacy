-- ============================================================================
-- W2-12 (#37) — psql acceptance checks for 20261106000017_docs_training.sql:
--   controlled document register (FR-DOC-01, NFR-09), training records
--   (FR-TRN-01), statutory designations (FR-ACC-02/03).
--
-- SELF-CONTAINED: seeds its own @w2dt.test / 'W2DT%' namespace (two
-- practices, two clients, one programme each, a test jurisdiction pack) and
-- never reads or mutates the shared TESTFIX world. Re-runnable: the
-- namespace is wiped first and torn down at the end.
--
-- JWT callers: each block runs in one transaction with SET LOCAL ROLE
-- authenticated + SET LOCAL request.jwt.claims (both end at COMMIT).
-- pg_temp.err(sql) runs one statement in a subtransaction and returns the
-- error text (NULL on success). Ids cross transactions via w2dt.* GUCs.
--
-- NOTE for local scratch runs: same auth shim as e2e_template_engine.sql.
--
-- Run (against the ephemeral/CI stack):
--   psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=0 \
--        -f app/tests/e2e_docs_training.sql
-- ============================================================================
\set QUIET on
\pset pager off

CREATE OR REPLACE FUNCTION pg_temp.t(cond boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(cond, false) THEN RAISE NOTICE 'PASS %', label;
  ELSE RAISE WARNING 'FAIL %', label; END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.err(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;

-- ---------- wipe any earlier run ----------
DELETE FROM client_orgs WHERE name LIKE 'W2DT%';
DELETE FROM practices WHERE name LIKE 'W2DT%';
DELETE FROM jurisdiction_packs WHERE code = 'W2DT';
DELETE FROM audit_log WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w2dt.test');
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w2dt.test');
DELETE FROM users WHERE email LIKE '%@w2dt.test';
DELETE FROM auth.users WHERE email LIKE '%@w2dt.test';

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
  ('a2d00000-0000-0000-0000-000000000001'::uuid, 'padmin@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000002'::uuid, 'pcons@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000003'::uuid, 'ao@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000004'::uuid, 'cadmin@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000005'::uuid, 'staff1@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000006'::uuid, 'staff2@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000007'::uuid, 'badmin@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000008'::uuid, 'ro@w2dt.test'),
  ('a2d00000-0000-0000-0000-000000000009'::uuid, 'exec@w2dt.test'),
  ('a2d00000-0000-0000-0000-00000000000a'::uuid, 'nobody@w2dt.test')
) AS u(id, email);
INSERT INTO users (id, email, full_name)
SELECT id, email, CASE email WHEN 'staff1@w2dt.test' THEN 'Sam Staff' END
  FROM auth.users WHERE email LIKE '%@w2dt.test';

-- test pack: partners may hold 'dpo' here (D4); every other role client-only
INSERT INTO jurisdiction_packs (code, version, role_labels)
VALUES ('W2DT', 0, '{"designation_holders": {"dpo": ["client","partner"]}}'::jsonb);

INSERT INTO practices (id, name) VALUES
  ('b2d00000-0000-0000-0000-00000000000a', 'W2DT Alpha'),
  ('b2d00000-0000-0000-0000-00000000000b', 'W2DT Beta');
INSERT INTO client_orgs (id, practice_id, name, jurisdiction) VALUES
  ('c2d00000-0000-0000-0000-00000000000a', 'b2d00000-0000-0000-0000-00000000000a', 'W2DT Client A', 'W2DT'),
  ('c2d00000-0000-0000-0000-00000000000b', 'b2d00000-0000-0000-0000-00000000000b', 'W2DT Client B', NULL);
INSERT INTO programmes (id, client_org_id, name, start_date, total_weeks) VALUES
  ('d2d00000-0000-0000-0000-000000000001', 'c2d00000-0000-0000-0000-00000000000a',
   'W2DT P1', date_trunc('week', CURRENT_DATE)::date - 28, 20),
  ('d2d00000-0000-0000-0000-000000000002', 'c2d00000-0000-0000-0000-00000000000b',
   'W2DT P2', date_trunc('week', CURRENT_DATE)::date - 28, 20);
INSERT INTO activities (id, programme_id, ref, text, leads, start_week, end_week, status) VALUES
  ('f2d00000-0000-0000-0000-000000000001','d2d00000-0000-0000-0000-000000000001','DT-A1','approve policy','{}',1,10,'Not started'),
  ('f2d00000-0000-0000-0000-000000000002','d2d00000-0000-0000-0000-000000000002','DT-B1','other client','{}',1,10,'Not started');
INSERT INTO documents (id, client_org_id, original_filename, mime, size, sha256, storage_path) VALUES
  ('e2d00000-0000-0000-0000-000000000001','c2d00000-0000-0000-0000-00000000000a','io-appointment.pdf',
   'application/pdf', 10, repeat('a', 64), 'w2dt/a/appointment'),
  ('e2d00000-0000-0000-0000-000000000002','c2d00000-0000-0000-0000-00000000000b','other.pdf',
   'application/pdf', 10, repeat('b', 64), 'w2dt/b/other');

-- padmin: partner_admin Alpha · pcons: partner_consultant at client A scope ·
-- ao: accountable_officer A · cadmin: client_admin A · staff1: contributor A ·
-- staff2: programme_lead on P1 (programme scope) · badmin: partner_admin Beta ·
-- ro: partner read_only Alpha · exec: executive A · nobody: no role
INSERT INTO role_assignments (user_id, level, role, scope_type, scope_id, start_date, end_date) VALUES
  ('a2d00000-0000-0000-0000-000000000001','partner','partner_admin','partner','b2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000002','partner','partner_consultant','client','c2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000003','client','accountable_officer','client','c2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000004','client','client_admin','client','c2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000005','client','client_contributor','client','c2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000006','client','programme_lead','programme','d2d00000-0000-0000-0000-000000000001', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000007','partner','partner_admin','partner','b2d00000-0000-0000-0000-00000000000b', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000008','partner','read_only','partner','b2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL),
  ('a2d00000-0000-0000-0000-000000000009','client','executive','client','c2d00000-0000-0000-0000-00000000000a', CURRENT_DATE, NULL);

-- ============================================================================
-- A. CONTROLLED DOCUMENTS
-- ============================================================================
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v uuid; e text;
BEGIN
  v := public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a',
         'POL-01', 'Privacy policy', '1.0', 'DPO office', NULL, NULL);
  PERFORM set_config('w2dt.doc1', v::text, false);
  PERFORM pg_temp.t((SELECT status = 'draft' AND created_by = auth.uid()
                       FROM public.controlled_documents WHERE id = v),
    '01 partner_admin registers POL-01 v1.0 as a draft (created_by stamped)');

  e := pg_temp.err($q$SELECT public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a',
         'POL-01', 'Privacy policy', '1.1')$q$);
  PERFORM pg_temp.t(e LIKE '%open draft%', '02 a second draft of the same reference is refused: '||coalesce(e,'(none)'));

  e := pg_temp.err(format($q$SELECT public.update_controlled_document(%L, p_approval_date => DATE '2026-01-10')$q$, v));
  e := coalesce(e, pg_temp.err(format($q$SELECT public.set_document_review_date(%L, DATE '2026-01-01')$q$, v)));
  PERFORM pg_temp.t(e LIKE '%after the approval date%',
    '03 review date on/before the approval date is refused: '||coalesce(e,'(none)'));

  PERFORM public.update_controlled_document(v, p_title => 'Privacy policy (POPIA)');
  PERFORM public.link_document_activity(v, 'f2d00000-0000-0000-0000-000000000001');
  e := pg_temp.err(format($q$SELECT public.link_document_activity(%L, 'f2d00000-0000-0000-0000-000000000002')$q$, v));
  PERFORM pg_temp.t(e LIKE '%another client%'
    AND (SELECT title FROM public.controlled_documents WHERE id = v) = 'Privacy policy (POPIA)'
    AND (SELECT count(*) FROM public.controlled_document_activities WHERE controlled_document_id = v) = 1,
    '04 draft edits + same-client activity link OK; another client''s activity refused');

  e := pg_temp.err($q$INSERT INTO public.controlled_documents (client_org_id, reference, title, version)
                      VALUES ('c2d00000-0000-0000-0000-00000000000a','RAW-1','raw','1')$q$);
  PERFORM pg_temp.t(e LIKE '%permission denied%', '05 direct INSERT into controlled_documents is refused (RPC-only): '||coalesce(e,'(none)'));
END $$;
COMMIT;

-- 06 read_only and another partner's admin cannot register; other tenant cannot list
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000008","role":"authenticated"}';
DO $$
DECLARE e1 text; n int;
BEGIN
  e1 := pg_temp.err($q$SELECT public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a',
          'POL-RO', 'x', '1')$q$);
  SELECT count(*) INTO n FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a');
  PERFORM set_config('w2dt.e1', coalesce(e1, ''), false);
  PERFORM set_config('w2dt.n_ro', n::text, false);
END $$;
COMMIT;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000007","role":"authenticated"}';
DO $$
DECLARE e2 text; e3 text;
BEGIN
  e2 := pg_temp.err($q$SELECT public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a',
          'POL-X', 'x', '1')$q$);
  e3 := pg_temp.err($q$SELECT * FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a')$q$);
  PERFORM pg_temp.t(current_setting('w2dt.e1') LIKE '%write role%' AND e2 LIKE '%write role%'
    AND e3 LIKE '%Access denied%' AND current_setting('w2dt.n_ro')::int = 1,
    '06 read_only reads but cannot register; other partner can neither register nor list');
END $$;
COMMIT;

-- 07 the accountable officer issues v1.0; issued content is then immutable
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE v uuid := current_setting('w2dt.doc1')::uuid; e text; e2 text;
BEGIN
  e := pg_temp.err(format($q$SELECT public.issue_controlled_document(%L, CURRENT_DATE + 1)$q$, v));
  PERFORM public.issue_controlled_document(v, CURRENT_DATE - 10);
  PERFORM pg_temp.t(e LIKE '%future%' AND (SELECT status = 'issued' AND approval_date = CURRENT_DATE - 10
                                   AND issued_by = auth.uid() AND issued_at IS NOT NULL
                                FROM public.controlled_documents WHERE id = v),
    '07 AO issues v1.0 (future approval date refused); issue stamp recorded');
  e2 := pg_temp.err(format($q$SELECT public.update_controlled_document(%L, p_title => 'edited')$q$, v));
  PERFORM pg_temp.t(e2 LIKE '%write role%', '08a AO is not a document editor: '||coalesce(e2,'(none)'));
END $$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v uuid := current_setting('w2dt.doc1')::uuid; e text;
BEGIN
  e := pg_temp.err(format($q$SELECT public.update_controlled_document(%L, p_title => 'edited')$q$, v));
  PERFORM pg_temp.t(e LIKE '%new version%', '08 editing an issued version via RPC is refused (NFR-09): '||coalesce(e,'(none)'));
END $$;
COMMIT;

-- 09 even the service path cannot rewrite issued content (trigger)
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err(format($q$UPDATE public.controlled_documents SET title = 'tampered' WHERE id = %L$q$,
                          current_setting('w2dt.doc1')));
  PERFORM pg_temp.t(e LIKE '%immutable%', '09 service-path UPDATE of issued content blocked by trigger: '||coalesce(e,'(none)'));
END $$;

-- 10 new version v2.0 issued by programme_lead (programme scope) supersedes v1.0
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000006","role":"authenticated"}';
DO $$
DECLARE v1 uuid := current_setting('w2dt.doc1')::uuid; v2 uuid; e text;
BEGIN
  v2 := public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a',
          'POL-01', 'Privacy policy (POPIA)', '2.0', 'DPO office');
  PERFORM set_config('w2dt.doc2', v2::text, false);
  PERFORM public.issue_controlled_document(v2);
  e := pg_temp.err(format($q$SELECT public.set_document_review_date(%L, CURRENT_DATE + 300)$q$, v1));
  -- programme-scope roles are outside allowed_client_orgs (table RLS), so
  -- read through the definer list RPC (can_read_client_records)
  PERFORM pg_temp.t(
    (SELECT status FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = v1) = 'superseded'
    AND (SELECT status FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = v2) = 'issued'
    AND e LIKE '%superseded%',
    '10 v2.0 issue supersedes v1.0; the superseded row is frozen: '||coalesce(e,'(none)'));
END $$;
COMMIT;

-- 11 review flags come from the server clock (overdue / due_soon / ok / none)
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE v2 uuid := current_setting('w2dt.doc2')::uuid; a uuid; b uuid; c uuid; s1 text; s2 text; s3 text; s4 text;
BEGIN
  PERFORM public.set_document_review_date(v2, CURRENT_DATE + 200);           -- issued: allowed (D1)
  a := public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a', 'PRO-01', 'DSR procedure', '1');
  b := public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a', 'PRO-02', 'Breach procedure', '1');
  c := public.register_controlled_document('c2d00000-0000-0000-0000-00000000000a', 'PRO-03', 'Retention procedure', '1');
  PERFORM public.set_document_review_date(a, CURRENT_DATE - 1);
  PERFORM public.set_document_review_date(b, CURRENT_DATE + 7);
  PERFORM set_config('w2dt.doc_c', c::text, false);
  SELECT review_state INTO s1 FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = a;
  SELECT review_state INTO s2 FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = b;
  SELECT review_state INTO s3 FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = v2;
  SELECT review_state INTO s4 FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a') WHERE id = c;
  PERFORM pg_temp.t(s1 = 'overdue' AND s2 = 'due_soon' AND s3 = 'ok' AND s4 = 'none',
    format('11 review_state from server dates: overdue=%s due_soon=%s ok=%s none=%s', s1, s2, s3, s4));
END $$;
COMMIT;

-- 12 withdrawal: issued needs a reason; withdrawn rows filtered unless asked
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE v2 uuid := current_setting('w2dt.doc2')::uuid; c uuid := current_setting('w2dt.doc_c')::uuid;
        e text; n_def int; n_all int;
BEGIN
  e := pg_temp.err(format($q$SELECT public.withdraw_controlled_document(%L)$q$, v2));
  PERFORM public.withdraw_controlled_document(c);                 -- draft: no reason needed
  SELECT count(*) INTO n_def FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a');
  SELECT count(*) INTO n_all FROM public.list_controlled_documents('c2d00000-0000-0000-0000-00000000000a', true);
  PERFORM pg_temp.t(e LIKE '%reason%' AND n_def = 4 AND n_all = 5
    AND (SELECT withdrawn_by = auth.uid() FROM public.controlled_documents WHERE id = c),
    format('12 issued withdrawal needs a reason; withdrawn rows hidden by default (%s of %s)', n_def, n_all));
END $$;
COMMIT;

-- ============================================================================
-- B. TRAINING RECORDS
-- ============================================================================
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE r uuid; e1 text; e2 text; e3 text;
BEGIN
  r := public.record_training('c2d00000-0000-0000-0000-00000000000a', 'Jane Doe', 'POPIA induction',
         CURRENT_DATE - 3, true, 'Head office', 'Finance');
  PERFORM set_config('w2dt.tr1', r::text, false);
  e1 := pg_temp.err($q$SELECT public.record_training('c2d00000-0000-0000-0000-00000000000a', 'jane doe ',
          'POPIA Induction', CURRENT_DATE - 3)$q$);
  e2 := pg_temp.err($q$SELECT public.record_training('c2d00000-0000-0000-0000-00000000000a', 'John', 'POPIA induction',
          CURRENT_DATE + 1)$q$);
  e3 := pg_temp.err($q$UPDATE public.training_records SET attendance = false WHERE person = 'Jane Doe'$q$);
  PERFORM pg_temp.t(e1 LIKE '%already has a record%' AND e2 LIKE '%future%' AND e3 LIKE '%permission denied%'
    AND (SELECT recorded_by = auth.uid() AND site = 'Head office' FROM public.training_records WHERE id = r),
    '13 client_admin records a completion; duplicate / future date / direct UPDATE refused');
END $$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000009","role":"authenticated"}';
DO $$
DECLARE e text; n int;
BEGIN
  e := pg_temp.err($q$SELECT public.record_training('c2d00000-0000-0000-0000-00000000000a', 'X', 'Y', CURRENT_DATE)$q$);
  SELECT count(*) INTO n FROM public.list_training_records('c2d00000-0000-0000-0000-00000000000a');
  PERFORM pg_temp.t(e LIKE '%training write role%' AND n = 1,
    '14 executive reads training records but cannot record: '||coalesce(e,'(none)'));
END $$;
COMMIT;

-- 15 the service path cannot edit a record; void-and-re-record is the correction
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err(format($q$UPDATE public.training_records SET session = 'tampered' WHERE id = %L$q$,
                          current_setting('w2dt.tr1')));
  PERFORM pg_temp.t(e LIKE '%void and re-record%', '15 service-path edit of a training record blocked: '||coalesce(e,'(none)'));
END $$;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
DECLARE r uuid := current_setting('w2dt.tr1')::uuid; e1 text; e2 text; n_def int; n_all int;
BEGIN
  e1 := pg_temp.err(format($q$SELECT public.void_training_record(%L, '  ')$q$, r));
  PERFORM public.void_training_record(r, 'wrong site');
  e2 := pg_temp.err(format($q$SELECT public.void_training_record(%L, 'again')$q$, r));
  PERFORM public.record_training('c2d00000-0000-0000-0000-00000000000a', 'Jane Doe', 'POPIA induction',
         CURRENT_DATE - 3, true, 'Branch office', 'Finance');
  SELECT count(*) INTO n_def FROM public.list_training_records('c2d00000-0000-0000-0000-00000000000a');
  SELECT count(*) INTO n_all FROM public.list_training_records('c2d00000-0000-0000-0000-00000000000a', true);
  PERFORM pg_temp.t(e1 LIKE '%reason%' AND e2 LIKE '%already voided%' AND n_def = 1 AND n_all = 2,
    '16 void needs a reason, is terminal; re-record allowed; voided rows hidden by default');
END $$;
COMMIT;

-- ============================================================================
-- C. DESIGNATIONS
-- ============================================================================
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000004","role":"authenticated"}';
DO $$
DECLARE e1 text; e2 text;
BEGIN
  e1 := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'named_alternate', 'a2d00000-0000-0000-0000-000000000005')$q$);
  e2 := pg_temp.err($q$INSERT INTO public.designations (client_org_id, role, person, date_designated)
          VALUES ('c2d00000-0000-0000-0000-00000000000a','named_alternate','a2d00000-0000-0000-0000-000000000004', CURRENT_DATE)$q$);
  PERFORM pg_temp.t(e1 LIKE '%requires partner_admin%' AND e2 LIKE '%permission denied%',
    '17 client_admin can neither appoint via RPC nor INSERT a designation directly (D3)');
END $$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'information_officer', 'a2d00000-0000-0000-0000-000000000003')$q$);
  PERFORM pg_temp.t(e LIKE '%themselves%', '18 the accountable officer cannot appoint themselves: '||coalesce(e,'(none)'));
END $$;
COMMIT;

-- 19 before appointment staff1 is not an alternate
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000005","role":"authenticated"}';
SELECT set_config('w2dt.alt_before', public.is_ao_or_alternate('c2d00000-0000-0000-0000-00000000000a')::text, false);
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE d uuid; e1 text; e2 text; e3 text; e4 text;
BEGIN
  d := public.appoint_designation('c2d00000-0000-0000-0000-00000000000a', 'named_alternate',
         'a2d00000-0000-0000-0000-000000000005', CURRENT_DATE - 30, NULL, NULL);
  PERFORM set_config('w2dt.alt', d::text, false);
  e1 := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'named_alternate', 'a2d00000-0000-0000-0000-000000000005')$q$);
  e2 := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'named_alternate', 'a2d00000-0000-0000-0000-00000000000a')$q$);
  e3 := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'named_alternate', 'a2d00000-0000-0000-0000-000000000006', CURRENT_DATE + 1)$q$);
  e4 := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'chief_of_everything', 'a2d00000-0000-0000-0000-000000000006')$q$);
  PERFORM pg_temp.t(
    (SELECT appointed_by = auth.uid() AND date_designated = CURRENT_DATE - 30 FROM public.designations WHERE id = d)
    AND e1 LIKE '%already holds%' AND e2 LIKE '%not eligible%' AND e3 LIKE '%future%' AND e4 LIKE '%unknown designation%',
    '19 partner_admin appoints a named alternate (backdated); duplicate / ineligible / future / unknown role refused');
END $$;
COMMIT;

-- 20 the appointment grants FR-ACC-02 powers
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.t(current_setting('w2dt.alt_before') = 'false'
    AND public.is_ao_or_alternate('c2d00000-0000-0000-0000-00000000000a'),
    '20 is_ao_or_alternate: false before appointment, true after');
END $$;
COMMIT;

-- 21 information officer is single: succession must be explicit
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE io1 uuid; io2 uuid; e text;
BEGIN
  io1 := public.appoint_designation('c2d00000-0000-0000-0000-00000000000a', 'information_officer',
           'a2d00000-0000-0000-0000-000000000006', CURRENT_DATE - 5, 'IR-REF-1');
  e := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'information_officer', 'a2d00000-0000-0000-0000-000000000005')$q$);
  io2 := public.appoint_designation('c2d00000-0000-0000-0000-00000000000a', 'information_officer',
           'a2d00000-0000-0000-0000-000000000005', CURRENT_DATE, NULL, NULL, true);
  PERFORM pg_temp.t(e LIKE '%confirm succession%'
    AND (SELECT end_date = CURRENT_DATE AND end_reason = 'succeeded' FROM public.designations WHERE id = io1)
    AND (SELECT end_date IS NULL FROM public.designations WHERE id = io2)
    AND (SELECT count(*) FROM public.designations
          WHERE client_org_id = 'c2d00000-0000-0000-0000-00000000000a'
            AND role = 'information_officer' AND end_date IS NULL) = 1,
    '21 AO appoints an IO; a 2nd IO needs explicit succession, which ends the 1st (history kept)');
END $$;
COMMIT;

-- 22 jurisdiction pack decides who may hold (D4): partner may hold dpo, not alternate
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE e text; d uuid;
BEGIN
  e := pg_temp.err($q$SELECT public.appoint_designation('c2d00000-0000-0000-0000-00000000000a',
          'named_alternate', 'a2d00000-0000-0000-0000-000000000002')$q$);
  d := public.appoint_designation('c2d00000-0000-0000-0000-00000000000a', 'dpo',
         'a2d00000-0000-0000-0000-000000000002');
  PERFORM pg_temp.t(e LIKE '%not eligible%' AND d IS NOT NULL,
    '22 pack designation_holders: partner consultant may hold dpo here, not named_alternate');
END $$;
COMMIT;

-- 23 appointment evidence: same-client document, set once
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000002","role":"authenticated"}';
DO $$
DECLARE d uuid := current_setting('w2dt.alt')::uuid; e1 text; e2 text; e3 text;
BEGIN
  e1 := pg_temp.err(format($q$SELECT public.set_designation_evidence(%L, 'e2d00000-0000-0000-0000-000000000002')$q$, d));
  PERFORM public.set_designation_evidence(d, 'e2d00000-0000-0000-0000-000000000001', 'IR-ALT-9');
  e2 := pg_temp.err(format($q$SELECT public.set_designation_evidence(%L, 'e2d00000-0000-0000-0000-000000000001')$q$, d));
  e3 := pg_temp.err(format($q$SELECT public.set_designation_evidence(%L, NULL, 'IR-OTHER')$q$, d));
  PERFORM pg_temp.t(e1 LIKE '%not found for this client%' AND e2 LIKE '%already attached%'
    AND e3 LIKE '%already recorded%'
    AND (SELECT evidence_filename = 'io-appointment.pdf' AND registration_ref = 'IR-ALT-9'
           FROM public.list_designations('c2d00000-0000-0000-0000-00000000000a') WHERE id = d),
    '23 evidence: other client''s document refused; attach + registration ref once; visible in list');
END $$;
COMMIT;

-- 24 end the alternate: powers stop TODAY (end_date exclusive), row kept
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000001","role":"authenticated"}';
DO $$
DECLARE d uuid := current_setting('w2dt.alt')::uuid; e1 text; e2 text; e3 text;
BEGIN
  e1 := pg_temp.err(format($q$SELECT public.end_designation(%L, '')$q$, d));
  PERFORM public.end_designation(d, 'left the organisation');
  e2 := pg_temp.err(format($q$SELECT public.end_designation(%L, 'again')$q$, d));
  e3 := pg_temp.err(format($q$DELETE FROM public.designations WHERE id = %L$q$, d));
  PERFORM pg_temp.t(e1 LIKE '%reason%' AND e2 LIKE '%already ended%' AND e3 LIKE '%permission denied%'
    AND (SELECT end_date = CURRENT_DATE AND ended_by = auth.uid() FROM public.designations WHERE id = d)
    AND NOT (SELECT is_current FROM public.list_designations('c2d00000-0000-0000-0000-00000000000a') WHERE id = d),
    '24 end_designation: reason required, terminal, never deleted; list marks it not current');
END $$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000005","role":"authenticated"}';
DO $$
BEGIN
  -- staff1 is still the current IO (appointed in 21), so check the alternate
  -- path specifically: holds_designation on named_alternate only
  PERFORM pg_temp.t(NOT public.holds_designation('c2d00000-0000-0000-0000-00000000000a', ARRAY['named_alternate']),
    '25 ended named_alternate no longer holds the designation on the end date itself');
END $$;
COMMIT;

-- 26 ended history is frozen even on the service path
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err(format($q$UPDATE public.designations SET end_date = NULL WHERE id = %L$q$,
                          current_setting('w2dt.alt')));
  PERFORM pg_temp.t(e LIKE '%frozen%', '26 service-path reopen of an ended designation blocked: '||coalesce(e,'(none)'));
END $$;

-- 27 candidates list is for appointers only, and excludes the caller
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000004","role":"authenticated"}';
SELECT set_config('w2dt.cand_err',
  coalesce(pg_temp.err($q$SELECT * FROM public.designation_candidates('c2d00000-0000-0000-0000-00000000000a','dpo')$q$), ''), false);
COMMIT;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"a2d00000-0000-0000-0000-000000000003","role":"authenticated"}';
DO $$
DECLARE ids uuid[];
BEGIN
  SELECT array_agg(id) INTO ids FROM public.designation_candidates('c2d00000-0000-0000-0000-00000000000a', 'named_alternate');
  PERFORM pg_temp.t(current_setting('w2dt.cand_err') LIKE '%appointing role%'
    AND NOT ('a2d00000-0000-0000-0000-000000000003' = ANY(ids))
    AND 'a2d00000-0000-0000-0000-000000000005' = ANY(ids)
    AND NOT ('a2d00000-0000-0000-0000-000000000002' = ANY(ids))
    AND NOT ('a2d00000-0000-0000-0000-00000000000a' = ANY(ids)),
    '27 designation_candidates: appointers only; client-level people, never the caller');
END $$;
COMMIT;

-- 28 every write left an audit trail
SELECT pg_temp.t(
  (SELECT count(DISTINCT action) FROM audit_log
    WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w2dt.test')
      AND action IN ('controlled_document.registered','controlled_document.updated',
                     'controlled_document.issued','controlled_document.linked',
                     'controlled_document.review_date_set','controlled_document.withdrawn',
                     'training_record.recorded','training_record.voided',
                     'designation.appointed','designation.ended',
                     'designation.evidence_recorded')) = 11,
  '28 audit_log carries every W2-12 write action');

-- ---------- teardown ----------
DELETE FROM client_orgs WHERE name LIKE 'W2DT%';
DELETE FROM practices WHERE name LIKE 'W2DT%';
DELETE FROM jurisdiction_packs WHERE code = 'W2DT';
DELETE FROM audit_log WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w2dt.test');
DELETE FROM role_assignments WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@w2dt.test');
DELETE FROM users WHERE email LIKE '%@w2dt.test';
DELETE FROM auth.users WHERE email LIKE '%@w2dt.test';
