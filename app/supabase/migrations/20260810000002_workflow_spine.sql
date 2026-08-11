-- WORKFLOW SPINE (2026-08-10) — the shared pipeline the Assessment-to-Management
-- spec (William, v1.0) hangs every stage off. Three primitives, nothing stage-specific:
--   (a) tracks + explicit stage state machine (+ append-only transition log)
--   (b) content packs: framework is CONTENT (registry + version), never a CHECK enum
--   (c) Draft(AI)/Approved + evidence: approvals ledger + a reusable status domain
-- Stage 1 (Devin's assessment engine) is refactored onto (b) here; Stages 2-6 build on this.
-- Every SECURITY DEFINER RPC guards allowed_client_orgs() explicitly (definer owned by a
-- superuser bypasses RLS — see 20260810000001).

BEGIN;

-- ========================================================================
-- (b) CONTENT PACKS — framework as content, not enum
-- ========================================================================
CREATE TABLE public.frameworks (
    key         text PRIMARY KEY,                 -- 'popia','paia','gdpr','iso27701','cyber_essentials'
    name        text NOT NULL,
    track_kind  text NOT NULL CHECK (track_kind IN ('privacy','cyber')),
    sort        int  NOT NULL DEFAULT 100
);
INSERT INTO public.frameworks (key, name, track_kind, sort) VALUES
  ('popia','POPIA', 'privacy', 10),
  ('paia','PAIA (s.51)', 'privacy', 20),
  ('gdpr','GDPR', 'privacy', 30),
  ('iso27701','ISO/IEC 27701', 'cyber', 40),
  ('cyber_essentials','Cyber Essentials', 'cyber', 50);
-- adding a framework later = one INSERT, zero schema change. That is the spec's acceptance test.

-- Versioned content container. practice_id NULL = global seed pack; a practice forking
-- content gets its own row/version. No version-management RPCs yet (built when a practice
-- first customises) — the schema carries the bones, the UI comes with the need.
CREATE TABLE public.content_packs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    practice_id   uuid REFERENCES public.practices(id),   -- NULL = global
    framework_key text NOT NULL REFERENCES public.frameworks(key),
    version       int  NOT NULL DEFAULT 1,
    label         text,
    status        text NOT NULL DEFAULT 'published' CHECK (status IN ('draft','published')),
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX content_packs_global_uq ON public.content_packs (framework_key, version)
  WHERE practice_id IS NULL;
CREATE UNIQUE INDEX content_packs_practice_uq ON public.content_packs (practice_id, framework_key, version)
  WHERE practice_id IS NOT NULL;

-- retire the CHECK enum on Devin's tables → FK to the registry (scoring joins on the text
-- value, so those RPCs are unchanged; parity preserved structurally).
ALTER TABLE public.assessment_questions DROP CONSTRAINT IF EXISTS assessment_questions_framework_check;
ALTER TABLE public.assessment_sessions  DROP CONSTRAINT IF EXISTS assessment_sessions_framework_check;
ALTER TABLE public.assessment_questions
  ADD CONSTRAINT assessment_questions_framework_fk FOREIGN KEY (framework) REFERENCES public.frameworks(key);
ALTER TABLE public.assessment_sessions
  ADD CONSTRAINT assessment_sessions_framework_fk FOREIGN KEY (framework) REFERENCES public.frameworks(key);
ALTER TABLE public.assessment_questions ADD COLUMN content_pack_id uuid REFERENCES public.content_packs(id);

-- backfill: one global pack per framework that currently has questions; stamp the questions.
INSERT INTO public.content_packs (practice_id, framework_key, version, label, status)
  SELECT DISTINCT NULL::uuid, framework, 1, 'Seed pack', 'published'
  FROM public.assessment_questions;
UPDATE public.assessment_questions q
  SET content_pack_id = cp.id
  FROM public.content_packs cp
  WHERE cp.practice_id IS NULL AND cp.framework_key = q.framework AND cp.version = 1;

ALTER TABLE public.frameworks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.frameworks FORCE ROW LEVEL SECURITY;
CREATE POLICY frameworks_read ON public.frameworks FOR SELECT TO authenticated USING (true);
ALTER TABLE public.content_packs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_packs FORCE ROW LEVEL SECURITY;
CREATE POLICY content_packs_read ON public.content_packs FOR SELECT TO authenticated
  USING (practice_id IS NULL OR practice_id = public.current_practice());
REVOKE ALL ON public.frameworks, public.content_packs FROM anon;
GRANT SELECT ON public.frameworks, public.content_packs TO authenticated;

-- ========================================================================
-- (a) TRACKS + EXPLICIT STAGE STATE (transitions logged, never a side effect)
-- ========================================================================
CREATE TABLE public.tracks (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_kind    text NOT NULL CHECK (track_kind IN ('privacy','cyber')),
    current_stage int  NOT NULL DEFAULT 0 CHECK (current_stage BETWEEN 0 AND 6),
    status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (client_org_id, track_kind)            -- one privacy + one cyber per client, run in parallel
);
CREATE TABLE public.stage_transitions (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    track_id   uuid NOT NULL REFERENCES public.tracks(id) ON DELETE CASCADE,
    from_stage int  NOT NULL,
    to_stage   int  NOT NULL,
    actor      uuid,
    note       text,
    at         timestamptz NOT NULL DEFAULT now()
);
-- link Stage 1 to its track (privacy). Nullable: existing sessions predate tracks.
ALTER TABLE public.assessment_sessions ADD COLUMN track_id uuid REFERENCES public.tracks(id);

ALTER TABLE public.tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tracks FORCE ROW LEVEL SECURITY;
CREATE POLICY tracks_read ON public.tracks FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));   -- writes via RPC only
ALTER TABLE public.stage_transitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stage_transitions FORCE ROW LEVEL SECURITY;
CREATE POLICY stage_transitions_read ON public.stage_transitions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.tracks t
                 WHERE t.id = stage_transitions.track_id
                   AND t.client_org_id IN (SELECT public.allowed_client_orgs())));
REVOKE ALL ON public.tracks, public.stage_transitions FROM anon;
GRANT SELECT ON public.tracks, public.stage_transitions TO authenticated;
REVOKE UPDATE, DELETE ON public.stage_transitions FROM authenticated;   -- append-only

-- ========================================================================
-- (c) DRAFT(AI)/APPROVED + evidence primitives
-- ========================================================================
-- reusable status for every artifact table Stages 3-6 add (policies, chapters, reports).
CREATE DOMAIN public.approval_status AS text
  CHECK (VALUE IN ('draft_ai','draft_human','approved','issued','superseded'));

-- append-only approval/gate ledger. Nothing AI-drafted is issued without a row here.
CREATE TABLE public.approvals (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    practice_id  uuid NOT NULL REFERENCES public.practices(id),
    subject_type text NOT NULL,                 -- 'assessment','policy','manual_chapter','monthly_report',...
    subject_id   uuid NOT NULL,
    action       text NOT NULL CHECK (action IN ('drafted','approved','issued','rejected','superseded')),
    actor        uuid,
    note         text,
    at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approvals FORCE ROW LEVEL SECURITY;
CREATE POLICY approvals_read ON public.approvals FOR SELECT TO authenticated
  USING (practice_id = public.current_practice());
REVOKE ALL ON public.approvals FROM anon;
GRANT SELECT ON public.approvals TO authenticated;
REVOKE UPDATE, DELETE ON public.approvals FROM authenticated;   -- append-only

-- Stage 1's gate becomes the first consumer of the primitive.
ALTER TABLE public.assessment_sessions
  ADD COLUMN approval_status public.approval_status NOT NULL DEFAULT 'draft_human';

-- ========================================================================
-- RPCs (SECURITY DEFINER, every one guards allowed_client_orgs / current_practice)
-- ========================================================================
CREATE FUNCTION public.create_track(p_client_org_id uuid, p_track_kind text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot create tracks'; END IF;
  INSERT INTO tracks (client_org_id, track_kind) VALUES (p_client_org_id, p_track_kind)
    ON CONFLICT (client_org_id, track_kind) DO UPDATE SET status = 'active'
    RETURNING id INTO tid;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'track.created',
            jsonb_build_object('track_id', tid, 'kind', p_track_kind, 'client_org_id', p_client_org_id));
  RETURN tid;
END $$;

-- Explicit, logged stage move. Never called as a side effect of anything else.
CREATE FUNCTION public.advance_track_stage(p_track_id uuid, p_to_stage int, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_track tracks%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_track FROM tracks WHERE id = p_track_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'track not found'; END IF;
  IF v_track.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to track';
  END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot advance stages'; END IF;
  IF p_to_stage NOT BETWEEN 0 AND 6 THEN RAISE EXCEPTION 'stage out of range'; END IF;
  INSERT INTO stage_transitions (track_id, from_stage, to_stage, actor, note)
    VALUES (p_track_id, v_track.current_stage, p_to_stage, auth.uid(), p_note);
  UPDATE tracks SET current_stage = p_to_stage WHERE id = p_track_id;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'track.stage_advanced',
            jsonb_build_object('track_id', p_track_id, 'from', v_track.current_stage, 'to', p_to_stage));
END $$;

-- Log an approval/gate event against any artifact. Frontend flips the artifact's
-- approval_status alongside; this ledger is the immutable proof.
CREATE FUNCTION public.record_approval(p_subject_type text, p_subject_id uuid, p_action text, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  pid := public.current_practice();
  IF pid IS NULL THEN RAISE EXCEPTION 'not a practice member'; END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot approve'; END IF;
  INSERT INTO approvals (practice_id, subject_type, subject_id, action, actor, note)
    VALUES (pid, p_subject_type, p_subject_id, p_action, auth.uid(), p_note);
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), pid, 'approval.' || p_action,
            jsonb_build_object('subject_type', p_subject_type, 'subject_id', p_subject_id));
END $$;

REVOKE EXECUTE ON FUNCTION
  public.create_track(uuid, text),
  public.advance_track_stage(uuid, int, text),
  public.record_approval(text, uuid, text, text)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.create_track(uuid, text),
  public.advance_track_stage(uuid, int, text),
  public.record_approval(text, uuid, text, text)
TO authenticated;

COMMIT;
