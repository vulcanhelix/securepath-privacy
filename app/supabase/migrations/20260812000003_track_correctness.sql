-- TRACK/STAGE CORRECTNESS (2026-08-12) — closes the shortcuts logged in the handoff:
--   1. Tracks are created at Stage 0 (client creation), not lazily at Gate 1 —
--      both privacy and cyber, so a new client has its pipeline instances from day one.
--   2. Starting an assessment moves the matching track 0→1 (explicit, logged), so
--      Gate 1 logs 1→2 instead of 0→2.
--   3. sign_off_assessment resolves the track from the assessment's framework
--      (frameworks.track_kind) — a cyber assessment now signs off a cyber track.
--   4. The Stage 1 baseline is SNAPSHOTTED onto the track at first sign-off and
--      immutable thereafter (editing the assessment can no longer drift the baseline).
--   5. list_assessable_frameworks() — the UI dropdown reads the registry, not a
--      hardcoded pair.

BEGIN;

-- ========================================================================
-- Baseline snapshot columns (immutable once set — first sign-off wins)
-- ========================================================================
ALTER TABLE public.tracks
  ADD COLUMN baseline_pct        int,
  ADD COLUMN baseline_rating     text,
  ADD COLUMN baseline_session_id uuid REFERENCES public.assessment_sessions(id),
  ADD COLUMN baseline_at         timestamptz;

-- ========================================================================
-- create_client_org — also creates both tracks at Stage 0 (same transaction
-- as the billable event; the pipeline instance exists before any assessment)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.create_client_org(
    p_name text, p_registration_no text DEFAULT NULL, p_industry text DEFAULT NULL,
    p_contact_name text DEFAULT NULL, p_contact_email text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; cid uuid;
BEGIN
  SELECT practice_id INTO pid FROM memberships
    WHERE user_id = auth.uid() AND role = 'practice_owner';
  IF pid IS NULL THEN RAISE EXCEPTION 'only practice owners may create client instances'; END IF;
  INSERT INTO client_orgs (practice_id, name, registration_no, industry, contact_name, contact_email)
    VALUES (pid, p_name, p_registration_no, p_industry, p_contact_name, p_contact_email)
    RETURNING id INTO cid;
  INSERT INTO tracks (client_org_id, track_kind)
    VALUES (cid, 'privacy'), (cid, 'cyber');
  INSERT INTO billing_events (practice_id, client_org_id, event_type, detail)
    VALUES (pid, cid, 'instance.created', jsonb_build_object('name', p_name, 'by', auth.uid()));
  INSERT INTO notifications (practice_id, kind, message)
    VALUES (pid, 'billing',
            format('Client instance "%s" created — this instance is billable.', p_name));
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'client_org.created', jsonb_build_object('client_org', cid, 'name', p_name));
  RETURN cid;
END $$;

-- backfill: every existing client gets both tracks (stage 0; existing rows untouched)
INSERT INTO public.tracks (client_org_id, track_kind)
  SELECT c.id, k.kind
  FROM public.client_orgs c
  CROSS JOIN (VALUES ('privacy'), ('cyber')) AS k(kind)
  ON CONFLICT (client_org_id, track_kind) DO NOTHING;

-- ========================================================================
-- create_assessment — link the session to its framework's track and move
-- that track 0→1 (explicit, logged: "assessment started" IS entering Stage 1)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.create_assessment(
    p_client_org_id UUID, p_framework TEXT, p_title TEXT, p_org_name TEXT,
    p_auditor_name TEXT, p_audit_date DATE, p_audit_ref TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE aid uuid; v_kind text; v_track uuid; v_stage int;
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
    v_track := public.create_track(p_client_org_id, v_kind);   -- legacy client pre-backfill
    v_stage := 0;
  END IF;

  INSERT INTO public.assessment_sessions
    (client_org_id, framework, title, org_name, auditor_name, audit_date, audit_ref, track_id)
  VALUES (p_client_org_id, p_framework, p_title, p_org_name, p_auditor_name, p_audit_date, p_audit_ref, v_track)
  RETURNING id INTO aid;

  IF v_stage = 0 THEN
    PERFORM public.advance_track_stage(v_track, 1, 'Stage 1: assessment started');
  END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.created',
          jsonb_build_object('assessment_id', aid, 'client_org_id', p_client_org_id));
  RETURN aid;
END $$;

-- ========================================================================
-- sign_off_assessment — track resolved from the framework; baseline snapshotted
-- ========================================================================
CREATE OR REPLACE FUNCTION public.sign_off_assessment(p_session_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.assessment_sessions%ROWTYPE; v_kind text; v_track uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'assessment not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may sign off an assessment';
  END IF;
  IF v.approval_status = 'approved' THEN RAISE EXCEPTION 'assessment already signed off'; END IF;

  -- the framework decides which pipeline this assessment belongs to
  SELECT track_kind INTO v_kind FROM frameworks WHERE key = v.framework;
  IF v_kind IS NULL THEN v_kind := 'privacy'; END IF;
  SELECT id INTO v_track FROM tracks WHERE client_org_id = v.client_org_id AND track_kind = v_kind;
  IF v_track IS NULL THEN
    v_track := public.create_track(v.client_org_id, v_kind);
  END IF;

  UPDATE assessment_sessions
    SET approval_status = 'approved', status = 'complete', track_id = v_track
    WHERE id = p_session_id;

  -- snapshot the baseline the whole relationship anchors on; first sign-off wins,
  -- immutable thereafter (annual reassessment gets its own delta mechanism)
  UPDATE tracks
    SET baseline_pct = v.score_pct, baseline_rating = v.rating,
        baseline_session_id = p_session_id, baseline_at = now()
    WHERE id = v_track AND baseline_at IS NULL;

  PERFORM public.record_approval('assessment', p_session_id, 'approved', 'Gate 1 sign-off');
  PERFORM public.advance_track_stage(v_track, 2, 'Gate 1: assessment signed off, into document intake');
END $$;

-- backfill baselines for tracks whose assessment was signed off before this migration
UPDATE public.tracks t
  SET baseline_pct = b.score_pct, baseline_rating = b.rating,
      baseline_session_id = b.id, baseline_at = COALESCE(b.updated_at, b.created_at)
  FROM (
    SELECT DISTINCT ON (s.client_org_id, f.track_kind)
           s.client_org_id, f.track_kind, s.id, s.score_pct, s.rating, s.updated_at, s.created_at
    FROM public.assessment_sessions s
    JOIN public.frameworks f ON f.key = s.framework
    WHERE s.approval_status = 'approved'
    ORDER BY s.client_org_id, f.track_kind, s.created_at ASC
  ) b
  WHERE t.client_org_id = b.client_org_id AND t.track_kind = b.track_kind
    AND t.baseline_at IS NULL;

-- ========================================================================
-- list_assessable_frameworks — registry-driven dropdown (only frameworks
-- that actually have questions; an empty assessment is a broken demo)
-- ========================================================================
CREATE FUNCTION public.list_assessable_frameworks()
RETURNS TABLE (key text, name text, track_kind text)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT f.key, f.name, f.track_kind
  FROM public.frameworks f
  WHERE EXISTS (SELECT 1 FROM public.assessment_questions q WHERE q.framework = f.key)
  ORDER BY f.sort;
$$;
REVOKE EXECUTE ON FUNCTION public.list_assessable_frameworks() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.list_assessable_frameworks() TO authenticated;

COMMIT;
