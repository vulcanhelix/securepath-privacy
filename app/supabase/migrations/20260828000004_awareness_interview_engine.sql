-- SECURITY & PRIVACY AWARENESS INTERVIEW — people-risk instrument (the Puris Section 8).
-- A small parallel engine mirroring the assessment-engine shapes: content questions on a
-- pack, per-department cohorts, per-respondent responses, alignment scoring. Advisor-
-- conducted MVP (the advisor keys answers during a confidential interview).
--
-- Privacy by design (dogfood POPIA): respondents carry NO name/email — identity is
-- respondent_no plus an optional advisor-entered label (initials) that never leaves the
-- raw tables. Raw interview data is advisor-only at RLS; client roles consume only the
-- anonymised aggregate via get_awareness_report().

BEGIN;

-- ---------- content: the instrument ----------
CREATE TABLE public.awareness_questions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    content_pack_id uuid NOT NULL REFERENCES public.content_packs(id),
    framework_key   text NOT NULL REFERENCES public.frameworks(key),
    domain_code     text NOT NULL,          -- 'ACC'
    domain_name     text NOT NULL,          -- 'Access & authentication'
    code            text NOT NULL,          -- 'ACC-04'
    question_number int  NOT NULL,          -- global display order
    question        text NOT NULL,
    good_answer     text NOT NULL CHECK (good_answer IN ('yes','no')),
    guidance        text,                   -- advisor-facing: what good practice looks like
    regulatory_ref  text,
    active          boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (content_pack_id, code)
);
CREATE INDEX awareness_questions_pack_idx ON public.awareness_questions (content_pack_id) WHERE active;

-- ---------- cohorts / respondents / responses ----------
CREATE TABLE public.awareness_cohorts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id   uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    framework_key   text NOT NULL REFERENCES public.frameworks(key),
    content_pack_id uuid NOT NULL REFERENCES public.content_packs(id),   -- pinned at create
    department      text NOT NULL,
    status          text NOT NULL DEFAULT 'in_progress'
                      CHECK (status IN ('in_progress','complete','archived')),
    interviewed_on  date,
    score_pct       int  CHECK (score_pct BETWEEN 0 AND 100),   -- snapshot at complete
    rating          text CHECK (rating IN ('low','medium','high')),
    notes           text,
    created_by      uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX awareness_cohorts_client_idx ON public.awareness_cohorts (client_org_id, created_at DESC);

CREATE TABLE public.awareness_respondents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cohort_id     uuid NOT NULL REFERENCES public.awareness_cohorts(id) ON DELETE CASCADE,
    respondent_no int  NOT NULL,
    label         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (cohort_id, respondent_no)
);
COMMENT ON COLUMN public.awareness_respondents.label IS
  'POPIA minimisation: optional advisor-entered initials/employee ref only — never name or email. Excluded from every results RPC and report; reports show "Respondent N".';

CREATE TABLE public.awareness_responses (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    respondent_id uuid NOT NULL REFERENCES public.awareness_respondents(id) ON DELETE CASCADE,
    question_id   uuid NOT NULL REFERENCES public.awareness_questions(id),
    answer        text NOT NULL CHECK (answer IN ('yes','no','unsure','na')),
    note          text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    UNIQUE (respondent_id, question_id)
);
CREATE INDEX awareness_responses_respondent_idx ON public.awareness_responses (respondent_id);

-- coverage denominator for the report's disclosed-limitation line
ALTER TABLE public.client_orgs ADD COLUMN IF NOT EXISTS awareness_departments_planned int
  CHECK (awareness_departments_planned IS NULL OR awareness_departments_planned > 0);
COMMENT ON COLUMN public.client_orgs.awareness_departments_planned IS
  'Advisor-entered count of departments in scope for the awareness interview programme. NULL = not yet scoped; the report must disclose a coverage limitation.';

-- ---------- RLS: raw interview data is advisor-only; writes via RPC only ----------
ALTER TABLE public.awareness_questions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.awareness_questions   FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.awareness_cohorts     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.awareness_cohorts     FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.awareness_respondents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.awareness_respondents FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.awareness_responses   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.awareness_responses   FORCE  ROW LEVEL SECURITY;

CREATE POLICY awareness_questions_read ON public.awareness_questions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY awareness_cohorts_read ON public.awareness_cohorts
  FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs())
         AND public.current_role_name() IN ('practice_owner','practice_consultant'));

CREATE POLICY awareness_respondents_read ON public.awareness_respondents
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.awareness_cohorts c
                 WHERE c.id = awareness_respondents.cohort_id
                   AND c.client_org_id IN (SELECT public.allowed_client_orgs())
                   AND public.current_role_name() IN ('practice_owner','practice_consultant')));

CREATE POLICY awareness_responses_read ON public.awareness_responses
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.awareness_respondents r
                 JOIN public.awareness_cohorts c ON c.id = r.cohort_id
                 WHERE r.id = awareness_responses.respondent_id
                   AND c.client_org_id IN (SELECT public.allowed_client_orgs())
                   AND public.current_role_name() IN ('practice_owner','practice_consultant')));

REVOKE ALL ON public.awareness_questions, public.awareness_cohorts,
              public.awareness_respondents, public.awareness_responses FROM anon;
GRANT SELECT ON public.awareness_questions, public.awareness_cohorts,
                public.awareness_respondents, public.awareness_responses TO authenticated;

-- ---------- helpers ----------
-- single source of banding truth: >=80 aligned = low risk, >=50 medium, else high
CREATE FUNCTION public.awareness_rating(p_pct numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_pct IS NULL THEN NULL
              WHEN p_pct >= 80 THEN 'low'
              WHEN p_pct >= 50 THEN 'medium'
              ELSE 'high' END
$$;

CREATE FUNCTION public.assert_awareness_cohort_writable(p_cohort_id uuid)
RETURNS public.awareness_cohorts LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v public.awareness_cohorts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM awareness_cohorts WHERE id = p_cohort_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'cohort not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to cohort';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may conduct awareness interviews';
  END IF;
  IF v.status <> 'in_progress' THEN
    RAISE EXCEPTION 'cohort is % — completed cohorts are immutable evidence', v.status;
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.assert_awareness_cohort_writable(uuid) FROM anon, public;

-- internal scoring core: one cohort's full results as jsonb (no auth — callers guard).
-- Anonymised by construction: respondent_no only, label never selected.
CREATE FUNCTION public.awareness_cohort_results(p_cohort_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH cohort AS (SELECT * FROM awareness_cohorts WHERE id = p_cohort_id),
  resp AS (
    SELECT r.id, r.respondent_no FROM awareness_respondents r WHERE r.cohort_id = p_cohort_id
  ),
  ans AS (
    SELECT a.respondent_id, q.id AS question_id, q.code, q.domain_code, q.domain_name,
           q.question, q.good_answer, q.regulatory_ref, q.question_number,
           (a.answer = q.good_answer) AS aligned
    FROM awareness_responses a
    JOIN resp r ON r.id = a.respondent_id
    JOIN awareness_questions q ON q.id = a.question_id
    WHERE a.answer <> 'na'
  ),
  per_q AS (
    SELECT code, domain_code, domain_name, question, good_answer, regulatory_ref,
           min(question_number) AS qn,
           count(*) AS answered, count(*) FILTER (WHERE aligned) AS aligned
    FROM ans GROUP BY code, domain_code, domain_name, question, good_answer, regulatory_ref
  ),
  per_d AS (
    SELECT domain_code, domain_name, min(qn) AS dn,
           sum(answered) AS answered, sum(aligned) AS aligned
    FROM per_q GROUP BY domain_code, domain_name
  ),
  per_r AS (
    SELECT r.respondent_no,
           count(a.respondent_id) AS answered,
           count(*) FILTER (WHERE a.aligned) AS aligned
    FROM resp r LEFT JOIN ans a ON a.respondent_id = r.id
    GROUP BY r.respondent_no
  ),
  totals AS (
    SELECT (SELECT count(*) FROM resp) AS respondents,
           COALESCE(sum(answered), 0) AS answered, COALESCE(sum(aligned), 0) AS aligned
    FROM per_q
  )
  SELECT jsonb_build_object(
    'id', c.id, 'department', c.department, 'interviewed_on', c.interviewed_on, 'status', c.status,
    'overall', (SELECT jsonb_build_object(
        'respondents', respondents, 'answered', answered, 'aligned', aligned,
        'pct', CASE WHEN answered > 0 THEN round(100.0 * aligned / answered) END,
        'rating', awareness_rating(CASE WHEN answered > 0 THEN 100.0 * aligned / answered END))
      FROM totals),
    'domains', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'code', domain_code, 'name', domain_name, 'answered', answered, 'aligned', aligned,
        'pct', round(100.0 * aligned / answered),
        'rating', awareness_rating(100.0 * aligned / answered)) ORDER BY dn)
      FROM per_d WHERE answered > 0), '[]'::jsonb),
    'high_risk_questions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'code', code, 'domain_code', domain_code, 'question', question,
        'good_answer', good_answer, 'answered', answered, 'aligned', aligned,
        'pct', round(100.0 * aligned / answered), 'regulatory_ref', regulatory_ref)
        ORDER BY round(100.0 * aligned / answered), qn)
      FROM per_q WHERE answered > 0 AND 100.0 * aligned / answered < 50), '[]'::jsonb),
    'respondents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'respondent_no', respondent_no, 'answered', answered, 'aligned', aligned,
        'pct', CASE WHEN answered > 0 THEN round(100.0 * aligned / answered) END,
        'rating', awareness_rating(CASE WHEN answered > 0 THEN 100.0 * aligned / answered END))
        ORDER BY respondent_no)
      FROM per_r), '[]'::jsonb)
  ) FROM cohort c
$$;
REVOKE EXECUTE ON FUNCTION public.awareness_cohort_results(uuid) FROM anon, public;

-- ---------- RPCs ----------
CREATE FUNCTION public.create_awareness_cohort(
    p_client_org_id uuid, p_department text, p_framework text DEFAULT 'popia',
    p_interviewed_on date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pack uuid; cid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may conduct awareness interviews';
  END IF;
  IF p_department IS NULL OR btrim(p_department) = '' THEN
    RAISE EXCEPTION 'department is required';
  END IF;

  -- pin the newest published GLOBAL pack that actually carries an awareness instrument
  SELECT cp.id INTO v_pack FROM content_packs cp
   WHERE cp.framework_key = p_framework AND cp.status = 'published' AND cp.practice_id IS NULL
     AND EXISTS (SELECT 1 FROM awareness_questions q WHERE q.content_pack_id = cp.id AND q.active)
   ORDER BY cp.version DESC LIMIT 1;
  IF v_pack IS NULL THEN RAISE EXCEPTION 'no published awareness instrument for framework %', p_framework; END IF;

  INSERT INTO awareness_cohorts (client_org_id, framework_key, content_pack_id, department, interviewed_on, notes, created_by)
    VALUES (p_client_org_id, p_framework, v_pack, btrim(p_department), p_interviewed_on, p_notes, auth.uid())
    RETURNING id INTO cid;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.cohort_created',
            jsonb_build_object('cohort_id', cid, 'client_org_id', p_client_org_id,
                               'department', btrim(p_department), 'content_pack_id', v_pack));
  RETURN cid;
END $$;

CREATE FUNCTION public.add_awareness_respondent(p_cohort_id uuid, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v awareness_cohorts%ROWTYPE; n int; rid uuid;
BEGIN
  v := public.assert_awareness_cohort_writable(p_cohort_id);
  SELECT COALESCE(max(respondent_no), 0) + 1 INTO n FROM awareness_respondents WHERE cohort_id = p_cohort_id;
  INSERT INTO awareness_respondents (cohort_id, respondent_no, label)
    VALUES (p_cohort_id, n, NULLIF(btrim(COALESCE(p_label, '')), ''))
    RETURNING id INTO rid;
  -- audit carries the number only — never the label
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.respondent_added',
            jsonb_build_object('cohort_id', p_cohort_id, 'respondent_no', n));
  RETURN jsonb_build_object('id', rid, 'respondent_no', n);
END $$;

CREATE FUNCTION public.remove_awareness_respondent(p_respondent_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cohort uuid; n int;
BEGIN
  SELECT cohort_id, respondent_no INTO v_cohort, n FROM awareness_respondents WHERE id = p_respondent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'respondent not found'; END IF;
  PERFORM public.assert_awareness_cohort_writable(v_cohort);
  DELETE FROM awareness_respondents WHERE id = p_respondent_id;   -- responses cascade
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.respondent_removed',
            jsonb_build_object('cohort_id', v_cohort, 'respondent_no', n));
END $$;

-- the one write path: batch upsert of a respondent's answers
-- p_answers = [{"question_id": uuid, "answer": "yes|no|unsure|na", "note": "optional"}, ...]
CREATE FUNCTION public.record_awareness_responses(p_respondent_id uuid, p_answers jsonb)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cohort awareness_cohorts%ROWTYPE; v_cohort_id uuid; item jsonb; qid uuid; ans text; cnt int := 0;
BEGIN
  SELECT cohort_id INTO v_cohort_id FROM awareness_respondents WHERE id = p_respondent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'respondent not found'; END IF;
  v_cohort := public.assert_awareness_cohort_writable(v_cohort_id);
  IF p_answers IS NULL OR jsonb_typeof(p_answers) <> 'array' THEN
    RAISE EXCEPTION 'p_answers must be a json array';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_answers) LOOP
    qid := (item->>'question_id')::uuid;
    ans := item->>'answer';
    IF ans NOT IN ('yes','no','unsure','na') THEN RAISE EXCEPTION 'invalid answer %', ans; END IF;
    -- the question must belong to the cohort's pinned pack and be active
    IF NOT EXISTS (SELECT 1 FROM awareness_questions q
                   WHERE q.id = qid AND q.content_pack_id = v_cohort.content_pack_id AND q.active) THEN
      RAISE EXCEPTION 'question % is not in this cohort''s instrument', qid;
    END IF;
    INSERT INTO awareness_responses (respondent_id, question_id, answer, note, updated_by)
      VALUES (p_respondent_id, qid, ans, item->>'note', auth.uid())
      ON CONFLICT (respondent_id, question_id) DO UPDATE
        SET answer = EXCLUDED.answer,
            note = COALESCE(EXCLUDED.note, awareness_responses.note),
            updated_at = now(), updated_by = auth.uid();
    cnt := cnt + 1;
  END LOOP;

  -- one audit row per save, not per answer (41 rows per interview would be noise)
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.responses_recorded',
            jsonb_build_object('cohort_id', v_cohort_id, 'respondent_id', p_respondent_id, 'count', cnt));
  RETURN cnt;
END $$;

-- live results for the capture screen (advisor-only — exposes per-respondent granularity)
CREATE FUNCTION public.compute_awareness_results(p_cohort_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v awareness_cohorts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM awareness_cohorts WHERE id = p_cohort_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'cohort not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to cohort';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may view raw interview results';
  END IF;
  RETURN public.awareness_cohort_results(p_cohort_id);
END $$;

-- complete = lock. Snapshots the score, writes the approvals ledger row.
CREATE FUNCTION public.complete_awareness_cohort(p_cohort_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v awareness_cohorts%ROWTYPE; res jsonb; v_pct int;
BEGIN
  v := public.assert_awareness_cohort_writable(p_cohort_id);
  IF NOT EXISTS (SELECT 1 FROM awareness_respondents WHERE cohort_id = p_cohort_id) THEN
    RAISE EXCEPTION 'cohort has no respondents';
  END IF;
  IF EXISTS (
    SELECT 1 FROM awareness_respondents r
    WHERE r.cohort_id = p_cohort_id
      AND NOT EXISTS (SELECT 1 FROM awareness_responses a
                      WHERE a.respondent_id = r.id AND a.answer <> 'na')
  ) THEN
    RAISE EXCEPTION 'every respondent needs at least one substantive answer before completion';
  END IF;

  res := public.awareness_cohort_results(p_cohort_id);
  v_pct := (res->'overall'->>'pct')::int;
  UPDATE awareness_cohorts
     SET status = 'complete', score_pct = v_pct, rating = awareness_rating(v_pct), updated_at = now()
   WHERE id = p_cohort_id;
  PERFORM public.record_approval('awareness_cohort', p_cohort_id, 'approved',
    'Awareness interview cohort completed — results locked (' || v.department || ')');
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.cohort_completed',
            jsonb_build_object('cohort_id', p_cohort_id, 'score_pct', v_pct));
  RETURN public.awareness_cohort_results(p_cohort_id);
END $$;

-- consultants scope the programme but client_orgs writes are owner-only at RLS — hence an RPC
CREATE FUNCTION public.set_awareness_departments_planned(p_client_org_id uuid, p_count int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may scope the awareness programme';
  END IF;
  IF p_count IS NOT NULL AND p_count < 1 THEN RAISE EXCEPTION 'planned departments must be positive'; END IF;
  UPDATE client_orgs SET awareness_departments_planned = p_count WHERE id = p_client_org_id;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'awareness.departments_planned',
            jsonb_build_object('client_org_id', p_client_org_id, 'count', p_count));
END $$;

-- the report-generator interface: anonymised aggregate over COMPLETED cohorts.
-- Callable by ANY role of the tenant (client roles included) — labels appear nowhere.
CREATE FUNCTION public.get_awareness_report(p_client_org_id uuid, p_framework text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_framework text := COALESCE(p_framework, 'popia');
        v_pack uuid; v_planned int; result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;

  SELECT awareness_departments_planned INTO v_planned FROM client_orgs WHERE id = p_client_org_id;

  -- instrument = newest published global pack with awareness questions for the framework
  SELECT cp.id INTO v_pack FROM content_packs cp
   WHERE cp.framework_key = v_framework AND cp.status = 'published' AND cp.practice_id IS NULL
     AND EXISTS (SELECT 1 FROM awareness_questions q WHERE q.content_pack_id = cp.id AND q.active)
   ORDER BY cp.version DESC LIMIT 1;

  WITH done AS (
    SELECT id, department FROM awareness_cohorts
    WHERE client_org_id = p_client_org_id AND framework_key = v_framework AND status = 'complete'
  ),
  in_prog AS (
    SELECT count(*) AS n FROM awareness_cohorts
    WHERE client_org_id = p_client_org_id AND framework_key = v_framework AND status = 'in_progress'
  ),
  -- pooled per-question over completed cohorts (each response joins its own cohort's pack)
  ans AS (
    SELECT q.code, q.domain_code, q.domain_name, q.question, q.good_answer,
           q.regulatory_ref, q.question_number,
           (a.answer = q.good_answer) AS aligned, r.id AS respondent_id
    FROM done d
    JOIN awareness_respondents r ON r.cohort_id = d.id
    JOIN awareness_responses a ON a.respondent_id = r.id
    JOIN awareness_questions q ON q.id = a.question_id
    WHERE a.answer <> 'na'
  ),
  per_q AS (
    SELECT code, domain_code, domain_name, question, good_answer, regulatory_ref,
           min(question_number) AS qn,
           count(*) AS answered, count(*) FILTER (WHERE aligned) AS aligned
    FROM ans GROUP BY code, domain_code, domain_name, question, good_answer, regulatory_ref
  ),
  per_d AS (
    SELECT domain_code, domain_name, min(qn) AS dn,
           sum(answered) AS answered, sum(aligned) AS aligned
    FROM per_q GROUP BY domain_code, domain_name
  ),
  totals AS (
    SELECT (SELECT count(DISTINCT respondent_id) FROM ans) AS respondents,
           COALESCE(sum(answered), 0) AS answered, COALESCE(sum(aligned), 0) AS aligned
    FROM per_q
  )
  SELECT jsonb_build_object(
    'available', EXISTS (SELECT 1 FROM done),
    'instrument', CASE WHEN v_pack IS NULL THEN NULL ELSE (
      SELECT jsonb_build_object(
        'framework_key', v_framework, 'content_pack_id', cp.id,
        'pack_label', cp.label, 'pack_version', cp.version,
        'question_count', (SELECT count(*) FROM awareness_questions q WHERE q.content_pack_id = cp.id AND q.active),
        'domains', (SELECT jsonb_agg(jsonb_build_object('code', domain_code, 'name', domain_name) ORDER BY dn)
                    FROM (SELECT domain_code, domain_name, min(question_number) AS dn
                          FROM awareness_questions WHERE content_pack_id = cp.id AND active
                          GROUP BY domain_code, domain_name) x))
      FROM content_packs cp WHERE cp.id = v_pack) END,
    'coverage', jsonb_build_object(
      'cohorts_completed', (SELECT count(*) FROM done),
      'cohorts_in_progress', (SELECT n FROM in_prog),
      'departments_covered', COALESCE((SELECT jsonb_agg(department ORDER BY department) FROM done), '[]'::jsonb),
      'departments_planned', v_planned,
      'limitation', v_planned IS NULL OR (SELECT count(*) FROM done) < v_planned),
    'overall', (SELECT jsonb_build_object(
        'respondents', respondents, 'answered', answered, 'aligned', aligned,
        'pct', CASE WHEN answered > 0 THEN round(100.0 * aligned / answered) END,
        'rating', awareness_rating(CASE WHEN answered > 0 THEN 100.0 * aligned / answered END))
      FROM totals),
    'domains', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'code', domain_code, 'name', domain_name, 'answered', answered, 'aligned', aligned,
        'pct', round(100.0 * aligned / answered),
        'rating', awareness_rating(100.0 * aligned / answered)) ORDER BY dn)
      FROM per_d WHERE answered > 0), '[]'::jsonb),
    'high_risk_questions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'code', code, 'domain_code', domain_code, 'question', question,
        'good_answer', good_answer, 'answered', answered, 'aligned', aligned,
        'pct', round(100.0 * aligned / answered), 'regulatory_ref', regulatory_ref)
        ORDER BY round(100.0 * aligned / answered), qn)
      FROM per_q WHERE answered > 0 AND 100.0 * aligned / answered < 50), '[]'::jsonb),
    'cohorts', COALESCE((SELECT jsonb_agg(public.awareness_cohort_results(d.id)) FROM done d), '[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

-- ---------- harden the assessment pack resolver (required interaction fix) ----------
-- The awareness instrument ships as the next global popia pack version. Without this,
-- create_assessment would pin new POPIA assessments to a pack with ZERO assessment
-- questions. Byte-identical to 20260827000002 apart from the EXISTS clause.
CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID, p_framework TEXT, p_title TEXT, p_org_name TEXT,
    p_auditor_name TEXT, p_audit_date DATE, p_audit_ref TEXT,
    p_org_scale TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE aid uuid; v_kind text; v_track uuid; v_stage int; v_scale text; v_pack uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() = 'read_only' THEN
    RAISE EXCEPTION 'read_only users cannot create assessments';
  END IF;

  SELECT track_kind INTO v_kind FROM frameworks WHERE key = p_framework;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'unknown framework %', p_framework; END IF;
  SELECT id, current_stage INTO v_track, v_stage
    FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = v_kind;
  IF v_track IS NULL THEN
    v_track := public.create_track(p_client_org_id, v_kind);
    v_stage := 0;
  END IF;

  v_scale := p_org_scale;
  IF v_scale IS NULL THEN
    SELECT org_scale INTO v_scale FROM client_orgs WHERE id = p_client_org_id;
  END IF;
  IF v_scale IS NULL THEN v_scale := 'large'; END IF;
  IF v_scale NOT IN ('sme', 'large') THEN RAISE EXCEPTION 'org_scale must be sme or large'; END IF;

  -- only packs that actually carry assessment questions qualify (an awareness-instrument
  -- pack shares the same framework/version namespace)
  SELECT cp.id INTO v_pack
    FROM public.content_packs cp
   WHERE cp.framework_key = p_framework AND cp.status = 'published' AND cp.practice_id IS NULL
     AND EXISTS (SELECT 1 FROM public.assessment_questions q
                 WHERE q.content_pack_id = cp.id AND q.active)
   ORDER BY cp.version DESC
   LIMIT 1;
  IF v_pack IS NULL THEN RAISE EXCEPTION 'no published content pack for framework %', p_framework; END IF;

  INSERT INTO public.assessment_sessions
    (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref, track_id, org_scale, content_pack_id)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref, v_track, v_scale, v_pack)
  RETURNING id INTO aid;

  IF v_stage = 0 THEN
    PERFORM public.advance_track_stage(v_track, 1, 'Stage 1: assessment started');
  END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.created',
          jsonb_build_object('assessment_id', aid, 'client_org_id', p_client_org_id, 'org_scale', v_scale, 'content_pack_id', v_pack));
  RETURN aid;
END $$;

-- ---------- grants ----------
REVOKE EXECUTE ON FUNCTION
  public.awareness_rating(numeric),
  public.create_awareness_cohort(uuid, text, text, date, text),
  public.add_awareness_respondent(uuid, text),
  public.remove_awareness_respondent(uuid),
  public.record_awareness_responses(uuid, jsonb),
  public.compute_awareness_results(uuid),
  public.complete_awareness_cohort(uuid),
  public.set_awareness_departments_planned(uuid, int),
  public.get_awareness_report(uuid, text)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.awareness_rating(numeric),
  public.create_awareness_cohort(uuid, text, text, date, text),
  public.add_awareness_respondent(uuid, text),
  public.remove_awareness_respondent(uuid),
  public.record_awareness_responses(uuid, jsonb),
  public.compute_awareness_results(uuid),
  public.complete_awareness_cohort(uuid),
  public.set_awareness_departments_planned(uuid, int),
  public.get_awareness_report(uuid, text)
TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
