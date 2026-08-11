-- STAGE 2 — Document intake & gap map (2026-08-10). Content-driven, on the spine.
-- The "expected documents" list is CONTENT (per framework, a content pack) — the same
-- screens must work for a Cyber Essentials pack with zero code change. Uploaded documents
-- are immutable evidence (corrections = new version). The gap map is a plain join of the
-- checklist against confirmed links — no bespoke query engine.

BEGIN;

-- ---------- expected-document checklist = content, per framework ----------
CREATE TABLE public.document_checklists (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_key  text NOT NULL REFERENCES public.frameworks(key),
    content_pack_id uuid REFERENCES public.content_packs(id),
    slot_key       text NOT NULL,                       -- stable id, e.g. 'paia_manual'
    name           text NOT NULL,
    description    text,
    category       text NOT NULL CHECK (category IN ('policy','notice','procedure','agreement','register','governance')),
    required       boolean NOT NULL DEFAULT true,
    sort           int NOT NULL DEFAULT 100,
    active         boolean NOT NULL DEFAULT true,
    UNIQUE (framework_key, slot_key)
);

-- ---------- uploaded documents = immutable evidence ----------
CREATE TABLE public.documents (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id     uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id          uuid REFERENCES public.tracks(id),
    original_filename text NOT NULL,
    mime              text NOT NULL,
    size              bigint NOT NULL CHECK (size > 0),
    sha256            text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_path      text NOT NULL UNIQUE,
    version           int  NOT NULL DEFAULT 1,
    supersedes        uuid REFERENCES public.documents(id),   -- correction = new version, never an edit
    uploaded_by       uuid,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------- gap map: which document fills which checklist slot ----------
-- AI proposes (status='proposed'); advisor confirms/rejects. A slot with no confirmed link = a gap.
CREATE TABLE public.document_links (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    checklist_id  uuid NOT NULL REFERENCES public.document_checklists(id),
    document_id   uuid NOT NULL REFERENCES public.documents(id) ON DELETE CASCADE,
    status        text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','confirmed','rejected')),
    confidence    numeric,
    linked_by     uuid,
    at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (checklist_id, document_id)
);

CREATE INDEX idx_documents_client ON public.documents (client_org_id, created_at DESC);
CREATE INDEX idx_document_links_client ON public.document_links (client_org_id);
CREATE INDEX idx_document_checklists_fw ON public.document_checklists (framework_key, sort);

-- ---------- RLS ----------
ALTER TABLE public.document_checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_checklists FORCE ROW LEVEL SECURITY;
CREATE POLICY document_checklists_read ON public.document_checklists FOR SELECT TO authenticated
  USING (true);                                          -- framework content, no tenant data

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents FORCE ROW LEVEL SECURITY;
CREATE POLICY documents_read ON public.documents FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));

ALTER TABLE public.document_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_links FORCE ROW LEVEL SECURITY;
CREATE POLICY document_links_read ON public.document_links FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));

REVOKE ALL ON public.document_checklists, public.documents, public.document_links FROM anon;
GRANT SELECT ON public.document_checklists, public.documents, public.document_links TO authenticated;
REVOKE UPDATE, DELETE ON public.documents FROM authenticated;   -- immutable evidence

-- ---------- RPCs (SECURITY DEFINER, guarded — writes go through these only) ----------
CREATE FUNCTION public.record_document(
    p_client_org_id uuid, p_track_id uuid, p_filename text, p_mime text,
    p_size bigint, p_sha256 text, p_storage_path text, p_supersedes uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE did uuid; v_version int := 1;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot upload'; END IF;
  IF p_supersedes IS NOT NULL THEN
    SELECT version + 1 INTO v_version FROM documents
      WHERE id = p_supersedes AND client_org_id = p_client_org_id;
    IF v_version IS NULL THEN RAISE EXCEPTION 'superseded document not in this client'; END IF;
  END IF;
  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256,
                         storage_path, version, supersedes, uploaded_by)
    VALUES (p_client_org_id, p_track_id, left(p_filename, 255), p_mime, p_size, p_sha256,
            p_storage_path, v_version, p_supersedes, auth.uid())
    RETURNING id INTO did;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'document.recorded',
            jsonb_build_object('document_id', did, 'client_org_id', p_client_org_id, 'version', v_version));
  RETURN did;
END $$;

-- AI proposes a slot fill; advisor confirms/rejects. Upsert on (checklist, document).
CREATE FUNCTION public.set_document_link(
    p_document_id uuid, p_checklist_id uuid, p_status text, p_confidence numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE lid uuid; v_client uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT client_org_id INTO v_client FROM documents WHERE id = p_document_id;
  IF v_client IS NULL THEN RAISE EXCEPTION 'document not found'; END IF;
  IF v_client NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to document';
  END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot classify'; END IF;
  IF p_status NOT IN ('proposed','confirmed','rejected') THEN RAISE EXCEPTION 'bad status'; END IF;
  INSERT INTO document_links (client_org_id, checklist_id, document_id, status, confidence, linked_by)
    VALUES (v_client, p_checklist_id, p_document_id, p_status, p_confidence, auth.uid())
    ON CONFLICT (checklist_id, document_id) DO UPDATE
      SET status = EXCLUDED.status, confidence = COALESCE(EXCLUDED.confidence, document_links.confidence),
          linked_by = auth.uid(), at = now()
    RETURNING id INTO lid;
  RETURN lid;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.record_document(uuid, uuid, text, text, bigint, text, text, uuid),
  public.set_document_link(uuid, uuid, text, numeric)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.record_document(uuid, uuid, text, text, bigint, text, text, uuid),
  public.set_document_link(uuid, uuid, text, numeric)
TO authenticated;

-- ---------- seed: POPIA expected-document checklist (STARTER — William to confirm/refine; it's content) ----------
INSERT INTO public.document_checklists (framework_key, content_pack_id, slot_key, name, category, required, sort, description)
SELECT 'popia', cp.id, x.slot_key, x.name, x.category, x.required, x.sort, x.description
FROM (SELECT id FROM public.content_packs WHERE practice_id IS NULL AND framework_key='popia' AND version=1) cp,
(VALUES
  ('paia_manual','PAIA Manual (s.51)','governance',true,10,'Statutory manual listing records held and access procedures.'),
  ('info_officer','Information Officer appointment & registration','governance',true,20,'IO designation and Regulator registration evidence.'),
  ('privacy_policy','Privacy / Data Protection Policy','policy',true,30,'Internal policy governing personal information processing.'),
  ('info_security_policy','Information Security Policy','policy',true,40,'Technical and organisational security measures (s.19).'),
  ('retention_policy','Data Retention & Disposal Policy','policy',true,50,'Retention periods and secure disposal.'),
  ('external_privacy_notice','External Privacy Notice','notice',true,60,'Customer/public-facing processing notice.'),
  ('employee_privacy_notice','Employee Privacy Notice','notice',false,70,'Staff-facing processing notice.'),
  ('ropa','Records of Processing Activities (ROPA)','register',true,80,'Inventory of processing operations.'),
  ('dsar_procedure','Data Subject Request Procedure','procedure',true,90,'Handling access/correction/deletion requests.'),
  ('breach_procedure','Data Breach Response Procedure','procedure',true,100,'Detection, containment, notification (s.22).'),
  ('operator_agreements','Operator (Processor) Agreements','agreement',true,110,'s.20/21 written contracts with operators.'),
  ('consent_records','Consent Management Records','register',false,120,'Evidence of consent where relied on.'),
  ('marketing_optout','Direct Marketing Consent & Opt-out Register','register',false,130,'s.69 direct marketing controls.'),
  ('crossborder','Cross-border Transfer Safeguards','agreement',false,140,'s.72 transfer basis and safeguards.'),
  ('training_records','POPIA Awareness / Training Records','register',false,150,'Staff training evidence.')
) AS x(slot_key,name,category,required,sort,description);

COMMIT;
