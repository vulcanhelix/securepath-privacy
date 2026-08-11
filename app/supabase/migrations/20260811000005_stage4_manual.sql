-- STAGE 4 — PIMS manual compilation. Content-driven, on the spine, ISO 27701-aligned.
-- The manual OUTLINE is content: chapters with a 27701 clause ref and the checklist slots
-- that feed each one. "Compile" assembles the manual from the client's approved policies and
-- confirmed documents, structured by that outline — so a privacy client arrives 27701-ready
-- (the cyber-track cross-sell, built into the document structure). Gate 3 = IO sign-off +
-- PAIA s.51 published, then Stage 5.

BEGIN;

-- ---------- manual outline = content, per framework (27701 clause architecture) ----------
CREATE TABLE public.manual_outlines (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_key  text NOT NULL REFERENCES public.frameworks(key),
    content_pack_id uuid REFERENCES public.content_packs(id),
    chapter_key    text NOT NULL,
    title          text NOT NULL,
    clause_ref     text,                         -- ISO/IEC 27701 clause the chapter aligns to
    narrative      text,                         -- chapter intro; compile appends the sourced artifacts
    source_slots   text[] NOT NULL DEFAULT '{}', -- checklist slot_keys whose documents populate this chapter
    sort           int NOT NULL DEFAULT 100,
    active         boolean NOT NULL DEFAULT true,
    UNIQUE (framework_key, chapter_key)
);

-- ---------- manual = compiled artifact, per client ----------
CREATE TABLE public.manuals (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id   uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id        uuid REFERENCES public.tracks(id),
    title           text NOT NULL,
    body            text NOT NULL DEFAULT '',
    approval_status public.approval_status NOT NULL DEFAULT 'draft_human',
    version         int NOT NULL DEFAULT 1,
    supersedes      uuid REFERENCES public.manuals(id),
    s51_published   boolean NOT NULL DEFAULT false,
    created_by      uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_manuals_client ON public.manuals (client_org_id, created_at DESC);

ALTER TABLE public.manual_outlines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_outlines FORCE ROW LEVEL SECURITY;
CREATE POLICY manual_outlines_read ON public.manual_outlines FOR SELECT TO authenticated USING (true);
ALTER TABLE public.manuals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manuals FORCE ROW LEVEL SECURITY;
CREATE POLICY manuals_read ON public.manuals FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
REVOKE ALL ON public.manual_outlines, public.manuals FROM anon;
GRANT SELECT ON public.manual_outlines, public.manuals TO authenticated;

-- ---------- RPCs (guarded) ----------
-- record a compiled draft (the compile step runs in the app, which builds the body)
CREATE FUNCTION public.record_manual(p_client_org_id uuid, p_title text, p_body text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE mid uuid; v_track uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to client organisation'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may compile the manual';
  END IF;
  SELECT id INTO v_track FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = 'privacy';
  -- supersede any earlier draft (only one working draft at a time)
  DELETE FROM manuals WHERE client_org_id = p_client_org_id AND approval_status IN ('draft_ai','draft_human');
  INSERT INTO manuals (client_org_id, track_id, title, body, created_by)
    VALUES (p_client_org_id, v_track, p_title, p_body, auth.uid())
    RETURNING id INTO mid;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'manual.compiled', jsonb_build_object('manual_id', mid));
  RETURN mid;
END $$;

-- Gate 3: IO sign-off. Publishes the manual as immutable evidence, marks PAIA s.51 published,
-- advances the track to Stage 5. Called server-side after the manual body is written to storage.
CREATE FUNCTION public.sign_off_manual(p_manual_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v manuals%ROWTYPE; did uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM manuals WHERE id = p_manual_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'manual not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to manual'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'only advisors or the client admin (IO) may sign off the manual';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN RAISE EXCEPTION 'manual already signed off'; END IF;

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid())
    RETURNING id INTO did;
  UPDATE manuals SET approval_status = 'issued', s51_published = true, updated_at = now() WHERE id = p_manual_id;
  PERFORM public.record_approval('manual', p_manual_id, 'issued', 'Gate 3: IO sign-off, PAIA s.51 published');
  -- advance the privacy track to Stage 5 (explicit, logged)
  IF v.track_id IS NOT NULL THEN
    PERFORM public.advance_track_stage(v.track_id, 5, 'Gate 3: PIMS manual signed off and s.51 published');
  END IF;
  RETURN did;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.record_manual(uuid, text, text),
  public.sign_off_manual(uuid, text, text, bigint)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.record_manual(uuid, text, text),
  public.sign_off_manual(uuid, text, text, bigint)
TO authenticated;

-- ---------- seed: POPIA/27701-aligned PIMS manual outline ----------
INSERT INTO public.manual_outlines (framework_key, content_pack_id, chapter_key, title, clause_ref, sort, source_slots, narrative)
SELECT 'popia', cp.id, x.chapter_key, x.title, x.clause_ref, x.sort, x.source_slots::text[], x.narrative
FROM (SELECT id FROM public.content_packs WHERE practice_id IS NULL AND framework_key='popia' AND version=1) cp,
(VALUES
  ('intro','Introduction & Scope','27701 cl.4', 10, '{}', 'Purpose, scope and boundaries of the Privacy Information Management System (PIMS).'),
  ('governance','Leadership & Information Officer','27701 cl.5', 20, '{io_appointment,io_registration,deputy_io,io_role_desc,governance_matrix}', 'Leadership commitment, the Information Officer, and governance responsibilities.'),
  ('planning','Planning & Risk Management','27701 cl.6', 30, '{risk_register}', 'Privacy risks and how they are treated.'),
  ('ropa','Records of Processing','27701 cl.7.2/8.2', 40, '{pi_inventory,special_pi_register,data_subject_categories,data_flow,asset_register,lawful_basis_register}', 'What personal information is processed, where it lives, and on what lawful basis.'),
  ('policies','Privacy Policy Framework','27701 cl.5.2', 50, '{privacy_policy,internal_privacy_policy,employee_privacy_notice}', 'The approved privacy policy suite.'),
  ('consent','Consent & Lawful Basis','27701 cl.7.2', 60, '{consent_records,lawful_basis_register}', 'How consent is obtained, recorded and withdrawn.'),
  ('dsr','Data Subject Rights','27701 cl.7.3', 70, '{dsr_procedure,dsr_log,dsr_identity_sop}', 'Handling access, correction, deletion and objection requests within statutory timeframes.'),
  ('breach','Breach Management','27701 cl.6/8', 80, '{breach_procedure,breach_register}', 'Detection, containment, notification and recording of security compromises (POPIA s.22).'),
  ('operators','Operators & Cross-border Transfers','27701 cl.7.5', 90, '{supplier_register,operator_agreements,crossborder_register,crossborder_assessment}', 'Operators processing PI and safeguards for transfers (POPIA s.20/21/72).'),
  ('retention','Retention & Disposal','27701 cl.7.4', 100, '{retention_schedule}', 'Retention periods and secure disposal (POPIA s.14).'),
  ('training','Awareness & Training','27701 cl.7.3', 110, '{io_training,staff_training_log}', 'Staff and Information Officer training.'),
  ('paia','PAIA s.51 Manual','PAIA s.51', 120, '{paia_manual,paia_annual_report}', 'The published PAIA manual and annual return position.'),
  ('review','Monitoring, Audit & Review','27701 cl.9/10', 130, '{}', 'How the PIMS is monitored, audited and improved.')
) AS x(chapter_key,title,clause_ref,sort,source_slots,narrative);

COMMIT;
