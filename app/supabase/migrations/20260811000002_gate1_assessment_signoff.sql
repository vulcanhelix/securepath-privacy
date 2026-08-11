-- GATE 1 — advisor signs off the Stage 1 assessment, which advances the client's privacy
-- track into Stage 2 (document intake). One explicit, logged, human-approved transition —
-- the first place the pipeline actually MOVES a client from one stage to the next.
-- Composes the spine RPCs (create_track, record_approval, advance_track_stage); each
-- re-guards, so authz is defence-in-depth.

CREATE FUNCTION public.sign_off_assessment(p_session_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.assessment_sessions%ROWTYPE; v_track uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM assessment_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'assessment not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to assessment';
  END IF;
  -- Gate 1 is an advisor action (spec: advisor review + client sign-off; MVP = advisor).
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may sign off an assessment';
  END IF;
  IF v.approval_status = 'approved' THEN RAISE EXCEPTION 'assessment already signed off'; END IF;

  -- the privacy track is the pipeline instance; create it if Stage 0 didn't
  SELECT id INTO v_track FROM tracks WHERE client_org_id = v.client_org_id AND track_kind = 'privacy';
  IF v_track IS NULL THEN
    v_track := public.create_track(v.client_org_id, 'privacy');
  END IF;

  UPDATE assessment_sessions
    SET approval_status = 'approved', status = 'complete', track_id = v_track
    WHERE id = p_session_id;

  PERFORM public.record_approval('assessment', p_session_id, 'approved', 'Gate 1 sign-off');
  PERFORM public.advance_track_stage(v_track, 2, 'Gate 1: assessment signed off, into document intake');
END $$;

REVOKE EXECUTE ON FUNCTION public.sign_off_assessment(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.sign_off_assessment(uuid) TO authenticated;
