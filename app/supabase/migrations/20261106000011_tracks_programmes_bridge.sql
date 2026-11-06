-- ============================================================================
-- W0-04 — TRACKS ⇄ PROGRAMMES BRIDGE: the v0.2 programme engine sits UNDER the
-- existing Stage 0-6 pipeline (GitHub #13 · William's product decision
-- 06/11/2026 · spec SP-SPC-PLT-001 §6.2, §8, §13)
-- ============================================================================
--
-- Product decision (final): v0.2 does not replace the old build. The Stage 0-6
-- pipeline (tracks / stage_transitions / advance_track_stage, content packs,
-- approvals) BECOMES the programme's implementation phase; Stage 6 becomes
-- Monthly Maintenance; assessment findings arrive through the §13 import
-- routes. Tenancy, auth, isolation, branding, audit and billing are unchanged.
--
-- ADDITIVE ONLY: no old migration is edited, no old function is redefined.
-- advance_track_stage / stage_transitions / approvals are untouched — the
-- hook below is an AFTER trigger on tracks, so a track with no linked
-- programme behaves byte-for-byte as before (e2e_pipeline.py stays green).
--
-- --------------------------- STAGE MAPPING ---------------------------------
--   track.current_stage   →   programmes.status
--   0  client setup        →   implementation
--   1  assessment          →   implementation
--   2  document intake     →   implementation
--   3  policy workbench    →   implementation
--   4  PIMS manual         →   implementation
--   5  implementation board→   implementation
--   6  managed service     →   maintenance   (Stage 6 = Monthly Maintenance)
-- Enforced by public.track_stage_programme_status(int). The mapping is
-- one-directional in time: programmes have no maintenance→implementation
-- move (W1-05 decision 5), so a track moved BACK from 6 leaves its programme
-- in maintenance (logged no-op, never an error that would break the old
-- pipeline). A closed programme is never touched by the hook.
--
-- --------------------------- DECISIONS --------------------------------------
-- 1. LINK SHAPE: programmes.track_id (nullable, UNIQUE, FK → tracks ON DELETE
--    SET NULL) rather than a bridge table. Why:
--      * the relation is 1:1 both ways (one programme per track, one track per
--        programme) — UNIQUE on one column states exactly that; a bridge table
--        needs two UNIQUEs to say the same thing.
--      * no new RLS surface: the link is read through the existing programmes
--        T1 policy; nothing new to isolate or get wrong.
--      * write-protected for free: programmes uses COLUMN-LEVEL grants (W0-02),
--        and a new column gets none — so authenticated can never set track_id
--        directly; only link_track_to_programme() (definer) writes it.
--      * lifecycle for free: deleting a track nulls the link; deleting a
--        programme removes it. No orphan rows to reconcile.
--    Same-client is enforced on EVERY write path by trg_programme_track_scope
--    (service_role / psql included), not only inside the RPC.
-- 2. SERVICE-PATH TRANSITION: the hook must use W1-05 transition_programme
--    semantics but cannot call transition_programme itself — that RPC gates on
--    has_programme_role(partner_admin|partner_consultant|programme_lead), and
--    legacy pipeline callers (e.g. a client_admin running Stage 5 RPCs) hold
--    none of those, so the old pipeline would start failing at Stage 6.
--    public.programme_transition_service() replicates the W1-05 legal-move
--    matrix verbatim (implementation→maintenance|closed, maintenance→closed,
--    closed terminal), writes status through ONE place and logs the same
--    'programme.transitioned' audit action (detail carries "via"). It is NOT
--    executable by anon/authenticated; its in-body guard admits the service
--    path (auth.uid() NULL) or a caller whose tenant scope covers the client
--    (allowed_client_orgs) — i.e. it is reachable by JWT callers only from
--    inside an already-guarded definer (advance_track_stage, link RPC).
--    If W1-05's matrix ever changes, change this function in the same PR.
-- 3. LINK CONSISTENCY: link_track_to_programme() applies the mapping at link
--    time too — a track already at Stage 6 moves an implementation programme
--    to maintenance; a track at Stage 0-5 cannot be linked to a programme
--    already in maintenance (the programme cannot go back — rejected, not
--    silently inconsistent). Closed programmes and archived tracks cannot be
--    linked. Any track_kind may link to any programme of the same client (the
--    template framework vs track kind is not policed — content, not code).
--    Re-linking the same pair is an idempotent no-op; there is no unlink RPC
--    in R1 (flagged — orchestrator can request one).
-- 4. FINDINGS = GAPS: a Stage 1 gap is an assessment_responses row with
--    response IN ('non_compliant','partial') (the scoring engine awards 0/1 of
--    2 points for these; 'na' and 'fully_compliant' are not gaps; unanswered
--    questions have no row). Priority from assessment_questions.risk:
--    Critical|High → High, Medium → Medium, Low → Low.
-- 5. PROVENANCE: register_items gains source_assessment_session_id +
--    source_question_ref (= assessment_questions.uid, the stable question key).
--    Both are write-protected (no column grant) — only the import writes them.
--    The idempotency key is UNIQUE (programme_id, source_assessment_session_id,
--    source_question_ref): re-importing the same session creates nothing;
--    a DIFFERENT session (e.g. annual reassessment) importing the same
--    question is a new finding with its own provenance.
--    register_items.ref = 'ASM-<question uid>' ('-<8 chars of session id>'
--    appended when that ref is already taken in the programme). The 'ASM-'
--    prefix keeps imported refs out of the template finding-ref namespace that
--    apply_template_version matches on (W1-05 merge rule).
-- 6. §13 TRAIL: every call writes ONE import_runs row (kind 'findings',
--    file_ref 'assessment_sessions:<id>', status 'committed' — the RPC is the
--    confirm step; there is no file to preview) and one import_rows row per
--    gap. import_rows.status is 'ok' for both outcomes; raw.outcome says
--    'created' or 'already_imported' and mapped_entity always names the
--    register item ('register_items:<uuid>'), so a re-import reconciles to the
--    same rows. The run's preview carries the counts.
-- 7. SIGN-OFF NOT REQUIRED: importing does not require Gate 1 sign-off
--    (approval_status 'approved'); the session's approval_status is recorded
--    in the run preview and on every raw row (flagged for William — easy to
--    tighten to approved-only).
-- 8. BACKFILL: none. Auto-creating programmes for existing tracks could breach
--    licence programme caps (W1-07). bridge_status() lists unlinked tracks per
--    client with the candidate (same-client, unlinked, not closed) programmes
--    so the orchestrator decides.
--
-- HARD RULES honoured: every SECURITY DEFINER guards tenant scope in its body;
-- stage_transitions + approvals stay append-only (not written here at all);
-- calc/status columns are written only by engine functions.
-- ============================================================================

BEGIN;

-- ---------- 1. schema: link column + provenance columns ----------

ALTER TABLE public.programmes
  ADD COLUMN track_id uuid UNIQUE REFERENCES public.tracks(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.programmes.track_id IS
  'W0-04: the legacy Stage 0-6 pipeline track this programme sits under '
  '(1:1, nullable). Written ONLY by link_track_to_programme (no column grant). '
  'Stage 0-5 ⇒ implementation, Stage 6 ⇒ maintenance (trg_track_stage_programme_sync).';

ALTER TABLE public.register_items
  ADD COLUMN source_assessment_session_id uuid
    REFERENCES public.assessment_sessions(id) ON DELETE SET NULL,
  ADD COLUMN source_question_ref text;
COMMENT ON COLUMN public.register_items.source_assessment_session_id IS
  'W0-04 provenance: the Stage 1 assessment session the finding was imported '
  'from (import_assessment_findings). Write-protected.';
COMMENT ON COLUMN public.register_items.source_question_ref IS
  'W0-04 provenance: assessment_questions.uid of the gap. Write-protected.';
CREATE UNIQUE INDEX register_items_assessment_source_uq
  ON public.register_items (programme_id, source_assessment_session_id, source_question_ref)
  WHERE source_assessment_session_id IS NOT NULL;


-- ---------- 2. stage mapping ----------

CREATE FUNCTION public.track_stage_programme_status(p_stage int) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_stage IS NULL OR p_stage NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION 'track stage % out of range (0..6)', p_stage;
  END IF;
  RETURN CASE WHEN p_stage = 6 THEN 'maintenance' ELSE 'implementation' END;
END $$;
COMMENT ON FUNCTION public.track_stage_programme_status(int) IS
  'W0-04 stage mapping: track stages 0-5 ⇒ programme status implementation, '
  'stage 6 (managed service / Monthly Maintenance) ⇒ maintenance.';


-- ---------- 3. service-path transition (W1-05 semantics) ----------

CREATE FUNCTION public.programme_transition_service(
    p_programme_id uuid, p_to_status text, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog     public.programmes;
  v_practice uuid;
BEGIN
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  -- in-body tenant guard (decision 2): service path, or a JWT caller whose
  -- scope covers the client (reached only from inside a guarded definer —
  -- EXECUTE is not granted to authenticated).
  IF auth.uid() IS NOT NULL
     AND v_prog.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to programme';
  END IF;
  -- W1-05 transition_programme matrix, verbatim
  IF p_to_status NOT IN ('implementation','maintenance','closed') THEN
    RAISE EXCEPTION 'invalid programme status "%"', p_to_status;
  END IF;
  IF p_to_status = v_prog.status THEN
    RAISE EXCEPTION 'programme is already %', p_to_status;
  END IF;
  IF NOT ( (v_prog.status = 'implementation' AND p_to_status IN ('maintenance','closed'))
        OR (v_prog.status = 'maintenance'    AND p_to_status = 'closed') ) THEN
    RAISE EXCEPTION 'invalid transition % → % (allowed: implementation→maintenance|closed, maintenance→closed)',
      v_prog.status, p_to_status;
  END IF;

  UPDATE public.programmes SET status = p_to_status WHERE id = p_programme_id;

  SELECT c.practice_id INTO v_practice FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'programme.transitioned',
          jsonb_build_object('programme_id', p_programme_id,
                             'from', v_prog.status, 'to', p_to_status)
          || COALESCE(p_detail, '{}'::jsonb));
END $$;
COMMENT ON FUNCTION public.programme_transition_service(uuid, text, jsonb) IS
  'W0-04 service-path twin of W1-05 transition_programme: identical legal-move '
  'matrix + audit action, without the programme-role caller gate. Not '
  'executable by authenticated; tenant guard in body. Used by the track hook '
  'and link_track_to_programme.';


-- ---------- 4. same-client guard on every write path ----------

CREATE FUNCTION public.trg_programme_track_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_track_client uuid;
BEGIN
  IF NEW.track_id IS NULL THEN RETURN NEW; END IF;
  SELECT client_org_id INTO v_track_client FROM public.tracks WHERE id = NEW.track_id;
  IF v_track_client IS DISTINCT FROM NEW.client_org_id THEN
    RAISE EXCEPTION 'a programme can only be linked to a track of the same client';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER programme_track_scope
BEFORE INSERT OR UPDATE OF track_id, client_org_id ON public.programmes
FOR EACH ROW EXECUTE FUNCTION public.trg_programme_track_scope();


-- ---------- 5. the Stage 6 hook ----------
-- AFTER UPDATE OF current_stage on tracks: tracks has no write grant for
-- authenticated, so this fires only from guarded definers
-- (advance_track_stage) or the service path. No linked programme ⇒ no-op.

CREATE FUNCTION public.trg_track_stage_programme_sync() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog   public.programmes;
  v_target text;
BEGIN
  IF NEW.current_stage IS NOT DISTINCT FROM OLD.current_stage THEN RETURN NEW; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE track_id = NEW.id;
  IF v_prog IS NULL THEN RETURN NEW; END IF;           -- unlinked: old pipeline untouched
  -- defence in depth: JWT callers must have scope on the track's client
  IF auth.uid() IS NOT NULL
     AND NEW.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to track';
  END IF;

  v_target := public.track_stage_programme_status(NEW.current_stage);
  IF v_target = 'maintenance' AND v_prog.status = 'implementation' THEN
    PERFORM public.programme_transition_service(v_prog.id, 'maintenance',
      jsonb_build_object('via', 'track_stage', 'track_id', NEW.id,
                         'from_stage', OLD.current_stage, 'to_stage', NEW.current_stage));
  ELSIF v_target IS DISTINCT FROM v_prog.status THEN
    -- stage moved back below 6, or programme closed: programmes never move
    -- back — record the divergence, never block the pipeline.
    INSERT INTO public.audit_log (user_id, practice_id, action, detail)
    SELECT auth.uid(), c.practice_id, 'programme.track_sync_skipped',
           jsonb_build_object('programme_id', v_prog.id, 'track_id', NEW.id,
                              'programme_status', v_prog.status,
                              'mapped_status', v_target,
                              'from_stage', OLD.current_stage, 'to_stage', NEW.current_stage)
      FROM public.client_orgs c WHERE c.id = NEW.client_org_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER track_stage_programme_sync
AFTER UPDATE OF current_stage ON public.tracks
FOR EACH ROW EXECUTE FUNCTION public.trg_track_stage_programme_sync();


-- ---------- 6. link_track_to_programme ----------

CREATE FUNCTION public.link_track_to_programme(p_track_id uuid, p_programme_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_track  public.tracks;
  v_prog   public.programmes;
  v_target text;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_track FROM public.tracks WHERE id = p_track_id FOR UPDATE;
  IF v_track IS NULL THEN RAISE EXCEPTION 'track not found'; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme not found'; END IF;

  -- in-body guards: tenant scope on BOTH sides, partner write role, same client
  IF v_track.client_org_id NOT IN (SELECT public.allowed_client_orgs())
     OR v_prog.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to track or programme';
  END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant']) THEN
    RAISE EXCEPTION 'linking a track requires a partner_admin or partner_consultant role on this programme';
  END IF;
  IF v_track.client_org_id <> v_prog.client_org_id THEN
    RAISE EXCEPTION 'cross-client link denied: track and programme belong to different clients';
  END IF;

  -- idempotent re-link
  IF v_prog.track_id = p_track_id THEN
    RETURN jsonb_build_object('programme_id', v_prog.id, 'track_id', p_track_id,
                              'programme_status', v_prog.status, 'changed', false);
  END IF;
  IF v_prog.track_id IS NOT NULL THEN
    RAISE EXCEPTION 'programme is already linked to another track';
  END IF;
  IF EXISTS (SELECT 1 FROM public.programmes WHERE track_id = p_track_id) THEN
    RAISE EXCEPTION 'track is already linked to another programme';
  END IF;
  IF v_track.status <> 'active' THEN
    RAISE EXCEPTION 'an archived track cannot be linked';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'a closed programme cannot be linked';
  END IF;

  v_target := public.track_stage_programme_status(v_track.current_stage);
  IF v_target = 'implementation' AND v_prog.status = 'maintenance' THEN
    RAISE EXCEPTION 'track is at stage % (implementation) but the programme is already in maintenance — programmes cannot move back',
      v_track.current_stage;
  END IF;

  UPDATE public.programmes SET track_id = p_track_id WHERE id = p_programme_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  SELECT auth.uid(), c.practice_id, 'programme.track_linked',
         jsonb_build_object('programme_id', p_programme_id, 'track_id', p_track_id,
                            'track_kind', v_track.track_kind,
                            'track_stage', v_track.current_stage)
    FROM public.client_orgs c WHERE c.id = v_prog.client_org_id;

  IF v_target = 'maintenance' AND v_prog.status = 'implementation' THEN
    PERFORM public.programme_transition_service(p_programme_id, 'maintenance',
      jsonb_build_object('via', 'track_link', 'track_id', p_track_id,
                         'track_stage', v_track.current_stage));
  END IF;

  SELECT status INTO v_status FROM public.programmes WHERE id = p_programme_id;
  RETURN jsonb_build_object('programme_id', p_programme_id, 'track_id', p_track_id,
                            'programme_status', v_status, 'changed', true);
END $$;
COMMENT ON FUNCTION public.link_track_to_programme(uuid, uuid) IS
  'W0-04: tie a legacy pipeline track to a programme of the SAME client. '
  'partner_admin/partner_consultant only; tenant scope checked on both rows. '
  'Applies the stage mapping at link time (stage 6 ⇒ programme to maintenance '
  'via the service-path transition).';


-- ---------- 7. import_assessment_findings (§13 findings route) ----------

CREATE FUNCTION public.import_assessment_findings(
    p_programme_id uuid, p_assessment_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog     public.programmes;
  v_sess     public.assessment_sessions;
  v_practice uuid;
  v_run      uuid;
  v_row_no   int := 0;
  v_created  int := 0;
  v_existing int := 0;
  v_gap      record;
  v_item     uuid;
  v_ref      text;
  v_outcome  text;
  v_window   text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- lock the programme: concurrent imports of the same session serialise here
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme not found'; END IF;
  SELECT * INTO v_sess FROM public.assessment_sessions WHERE id = p_assessment_session_id;
  IF v_sess IS NULL THEN RAISE EXCEPTION 'assessment session not found'; END IF;

  -- in-body guards
  IF v_prog.client_org_id NOT IN (SELECT public.allowed_client_orgs())
     OR v_sess.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to programme or assessment';
  END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant']) THEN
    RAISE EXCEPTION 'importing findings requires a partner_admin or partner_consultant role on this programme';
  END IF;
  IF v_sess.client_org_id <> v_prog.client_org_id THEN
    RAISE EXCEPTION 'cross-client import denied: the assessment belongs to a different client';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'findings cannot be imported into a closed programme';
  END IF;

  SELECT practice_id INTO v_practice FROM public.client_orgs WHERE id = v_prog.client_org_id;
  v_window := NULLIF(concat_ws(' · ', v_sess.title, v_sess.audit_date::text), '');

  INSERT INTO public.import_runs (partner_id, kind, file_ref, status, preview, created_by)
  VALUES (v_practice, 'findings', 'assessment_sessions:' || p_assessment_session_id,
          'committed', '{}'::jsonb, auth.uid())
  RETURNING id INTO v_run;

  FOR v_gap IN
    SELECT q.uid, q.question, q.risk, q.section_id, q.section_name, q.question_number,
           q.regulatory_ref, r.response, r.findings
      FROM public.assessment_responses r
      JOIN public.assessment_questions q ON q.id = r.question_id
     WHERE r.session_id = p_assessment_session_id
       AND r.response IN ('non_compliant','partial')
     ORDER BY q.section_id, q.question_number, q.uid
  LOOP
    v_row_no := v_row_no + 1;
    SELECT id INTO v_item FROM public.register_items
     WHERE programme_id = p_programme_id
       AND source_assessment_session_id = p_assessment_session_id
       AND source_question_ref = v_gap.uid;

    IF v_item IS NOT NULL THEN
      v_outcome  := 'already_imported';
      v_existing := v_existing + 1;
    ELSE
      v_ref := 'ASM-' || v_gap.uid;
      IF EXISTS (SELECT 1 FROM public.register_items
                  WHERE programme_id = p_programme_id AND ref = v_ref) THEN
        v_ref := v_ref || '-' || left(p_assessment_session_id::text, 8);
      END IF;
      INSERT INTO public.register_items
          (programme_id, ref, finding, priority, assessment_window,
           source_assessment_session_id, source_question_ref)
      VALUES (p_programme_id, v_ref,
              v_gap.question
                || CASE WHEN NULLIF(btrim(v_gap.findings), '') IS NOT NULL
                        THEN E'\n— ' || btrim(v_gap.findings) ELSE '' END,
              CASE v_gap.risk WHEN 'Critical' THEN 'High' WHEN 'High' THEN 'High'
                              WHEN 'Medium' THEN 'Medium' ELSE 'Low' END,
              v_window, p_assessment_session_id, v_gap.uid)
      RETURNING id INTO v_item;
      v_outcome := 'created';
      v_created := v_created + 1;
    END IF;

    INSERT INTO public.import_rows (import_run_id, row_no, raw, status, mapped_entity)
    VALUES (v_run, v_row_no,
            jsonb_build_object('assessment_session_id', p_assessment_session_id,
                               'question_ref', v_gap.uid,
                               'section', v_gap.section_name,
                               'question_number', v_gap.question_number,
                               'question', v_gap.question,
                               'regulatory_ref', v_gap.regulatory_ref,
                               'risk', v_gap.risk,
                               'response', v_gap.response,
                               'findings', v_gap.findings,
                               'approval_status', v_sess.approval_status,
                               'outcome', v_outcome),
            'ok', 'register_items:' || v_item);
  END LOOP;

  UPDATE public.import_runs
     SET preview = jsonb_build_object(
           'source', 'assessment_session',
           'assessment_session_id', p_assessment_session_id,
           'programme_id', p_programme_id,
           'framework', v_sess.framework,
           'approval_status', v_sess.approval_status,
           'rows', v_row_no, 'created', v_created,
           'already_imported', v_existing, 'rejected', 0)
   WHERE id = v_run;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'register.findings_imported',
          jsonb_build_object('programme_id', p_programme_id,
                             'assessment_session_id', p_assessment_session_id,
                             'import_run_id', v_run,
                             'created', v_created, 'already_imported', v_existing));

  RETURN jsonb_build_object('import_run_id', v_run, 'rows', v_row_no,
                            'created', v_created, 'already_imported', v_existing);
END $$;
COMMENT ON FUNCTION public.import_assessment_findings(uuid, uuid) IS
  'W0-04 §13 findings route: Stage 1 gaps (non_compliant/partial responses) '
  'become register_items with provenance (session + question uid). '
  'Idempotent per (programme, session, question). Writes an import_runs + '
  'import_rows reconciliation trail on every call. Partner write roles only.';


-- ---------- 8. bridge_status (read-only) ----------

CREATE FUNCTION public.bridge_status(p_client_org_id uuid DEFAULT NULL)
RETURNS TABLE(client_org_id uuid, client_name text, track_id uuid, track_kind text,
              current_stage int, track_status text, mapped_programme_status text,
              candidate_programme_ids uuid[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT t.client_org_id, c.name, t.id, t.track_kind, t.current_stage, t.status,
         public.track_stage_programme_status(t.current_stage),
         COALESCE((SELECT array_agg(p.id ORDER BY p.created_at)
                     FROM public.programmes p
                    WHERE p.client_org_id = t.client_org_id
                      AND p.track_id IS NULL
                      AND p.status <> 'closed'), '{}'::uuid[])
    FROM public.tracks t
    JOIN public.client_orgs c ON c.id = t.client_org_id
   WHERE NOT EXISTS (SELECT 1 FROM public.programmes p WHERE p.track_id = t.id)
     AND (p_client_org_id IS NULL OR t.client_org_id = p_client_org_id)
     -- in-body tenant guard: service path sees all; JWT callers their scope
     AND (auth.uid() IS NULL
          OR t.client_org_id IN (SELECT public.allowed_client_orgs()))
   ORDER BY c.name, t.client_org_id, t.track_kind
$$;
COMMENT ON FUNCTION public.bridge_status(uuid) IS
  'W0-04 read-only: tracks with NO linked programme, per client, with the '
  'mapped programme status and the candidate (same-client, unlinked, not '
  'closed) programmes. No backfill is automatic — licence caps (decision 8).';


-- ---------- 9. grants (W0-00 convention: lock the surface) ----------
REVOKE EXECUTE ON FUNCTION
  public.track_stage_programme_status(int),
  public.programme_transition_service(uuid, text, jsonb),
  public.trg_programme_track_scope(),
  public.trg_track_stage_programme_sync(),
  public.link_track_to_programme(uuid, uuid),
  public.import_assessment_findings(uuid, uuid),
  public.bridge_status(uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.track_stage_programme_status(int),
  public.link_track_to_programme(uuid, uuid),
  public.import_assessment_findings(uuid, uuid),
  public.bridge_status(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
  public.track_stage_programme_status(int),
  public.programme_transition_service(uuid, text, jsonb),
  public.bridge_status(uuid)
TO service_role;

COMMIT;
