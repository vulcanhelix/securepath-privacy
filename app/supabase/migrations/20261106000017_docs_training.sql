-- ============================================================================
-- W2-12 (#37) — DOCUMENT REGISTER, TRAINING RECORDS, STATUTORY DESIGNATIONS
-- (spec SP-SPC-PLT-001 FR-DOC-01, FR-TRN-01/02, FR-ACC-02/03, NFR-08/09/15)
-- ============================================================================
--
-- W1-06 left these three client-level tables (§6.1/§6.2) with table policies
-- and column grants but no write RPCs. This migration adds the RPCs, closes
-- the direct-table write paths (writes go through the definer RPCs only, each
-- with its role + tenant check in the body), and adds the version/status
-- columns the rules need.
--
-- 1. CONTROLLED DOCUMENTS (FR-DOC-01, NFR-09)
--    New columns: status draft|issued|superseded|withdrawn, issued_at/by,
--    created_by, withdrawn_at/by/reason. Existing rows (template-seeded) stay
--    'draft'. One row = one version of one reference (UNIQUE client,
--    reference, version already exists).
--      register_controlled_document  new version (draft); refused while the
--                                    reference already has an open draft
--      update_controlled_document    patch a DRAFT (title/owner/version/
--                                    approval_date); issued rows refuse
--      set_document_review_date      next_review_date on a draft or the
--                                    current issued version (D1)
--      link_document_activity /      FR-DOC-01 links to the activities that
--      unlink_document_activity      approve or reissue the document (same
--                                    client, live activity, live document)
--      issue_controlled_document     draft → issued (approval_date required,
--                                    not in the future); the previously
--                                    issued version of the reference becomes
--                                    'superseded' in the same transaction
--      withdraw_controlled_document  retire a draft or issued version (terminal)
--      list_controlled_documents     read: register + review_state computed
--                                    from the SERVER's CURRENT_DATE
--    Immutability is a trigger (trg_controlled_document_guard) so every write
--    path — RPCs, service, a future bug — is covered: an issued version's
--    content (reference/title/version/owner/approval_date/issue stamp) never
--    changes; a correction is a new version. superseded/withdrawn rows are
--    frozen entirely.
--
-- 2. TRAINING RECORDS (FR-TRN-01)
--    New columns: recorded_by, voided_at/by/reason. A record is evidence:
--      record_training        one completion per person + course (session)
--                             + date; date not in the future; duplicates refused
--      void_training_record   corrections void the row (reason required) and
--                             record a new one — never an edit (NFR-08 spirit)
--      list_training_records  read (voided rows excluded unless asked)
--    Guard trigger: only the void transition is an allowed UPDATE.
--
-- 3. DESIGNATIONS (FR-ACC-02/03). is_ao_or_alternate() trusts these rows, so
--    the write path is deliberately narrow:
--      appoint_designation      APPOINT set only: partner_admin,
--                               partner_consultant, accountable_officer (D3).
--                               Nobody may appoint themselves. The designee
--                               must be eligible per the client's jurisdiction
--                               pack (D4). date_designated may be backdated
--                               but never future. One current
--                               information_officer per client: replacing one
--                               needs p_supersede_current = true, which ends
--                               the old holder today in the same transaction.
--                               Same person + role twice concurrently refused.
--      end_designation          sets end_date = CURRENT_DATE (end_date is
--                               EXCLUSIVE, like role_assignments — the holder
--                               loses the powers immediately). Never deleted;
--                               ended rows are history. Reason recorded.
--      set_designation_evidence attach appointment evidence (an immutable
--                               public.documents row of the same client) and/or
--                               the regulator registration reference — once
--                               each, on a current designation.
--      list_designations        read: holder names resolved server-side
--      designation_candidates   eligible people (APPOINT roles only)
--    The T1 designations_write policy (FOR ALL, incl. client_admin and
--    DELETE) is dropped and INSERT/UPDATE/DELETE revoked: the RPCs are the
--    only write path. A guard trigger freezes identity columns and makes
--    end_date / evidence / registration_ref set-once.
--    holds_designation() now treats end_date as EXCLUSIVE (end_date >
--    CURRENT_DATE), matching role_assignments and the end_designation RPC.
--
-- DECISIONS (flagged for review):
--   D1 next_review_date stays settable on the CURRENT issued version: it is
--      a planning date (MM-19 review flag), not document content. A review
--      that confirms "no change" moves the date without minting a version.
--      approval_date is content and is frozen on issue.
--   D2 Document/training WRITE set mirrors the W1-06 table policies:
--      partner_admin, partner_consultant, programme_lead, client_admin.
--      Issuing additionally allows accountable_officer (the client approver).
--   D3 The spec role tables have no designation row. APPOINT = partner_admin
--      and partner_consultant (onboarding sets statutory designations,
--      FR-ONB-01) and the client's accountable_officer. client_admin (not a
--      spec role) is NOT included — it could otherwise mint a named_alternate
--      and inherit FR-ACC-02 closure powers.
--   D4 FR-ACC-03 "the jurisdiction pack sets who may hold each designation":
--      jurisdiction_packs.role_labels may carry a 'designation_holders' object
--      {"<role>": ["client"] | ["client","partner"]}. Absent (all packs today,
--      values unverified) ⇒ CLIENT-ONLY: the designee must hold an active
--      client-level assignment on this client (client or programme scope).
--      This is the conservative reading of the SA note ("a partner
--      organisation is recorded as providing DIO support, not as holding the
--      designation") and must be confirmed with SecurePath (open item 7).
--   D5 Other designation consumers (notifications fan-out, support-grant
--      approval) read "current" as end_date IS NULL. end_designation always
--      sets end_date = CURRENT_DATE and future date_designated is refused, so
--      every consumer agrees on who is current.
-- ============================================================================

BEGIN;

-- ---------- 1. schema additions ----------
ALTER TABLE public.controlled_documents
  ADD COLUMN status           text NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','issued','superseded','withdrawn')),
  ADD COLUMN issued_at        timestamptz,
  ADD COLUMN issued_by        uuid,          -- user id; no FK (evidence outlives the user row)
  ADD COLUMN created_by       uuid,
  ADD COLUMN withdrawn_at     timestamptz,
  ADD COLUMN withdrawn_by     uuid,
  ADD COLUMN withdrawn_reason text;
COMMENT ON COLUMN public.controlled_documents.status IS
  'W2-12 NFR-09: draft → issued → superseded (by the next issued version) | '
  'withdrawn. Issued content is immutable (trg_controlled_document_guard); '
  'a correction is a new version.';
CREATE INDEX controlled_documents_ref_idx
  ON public.controlled_documents (client_org_id, reference);
-- at most one issued (in-force) version per reference
CREATE UNIQUE INDEX controlled_documents_one_issued
  ON public.controlled_documents (client_org_id, reference) WHERE status = 'issued';

ALTER TABLE public.training_records
  ADD COLUMN recorded_by  uuid,
  ADD COLUMN voided_at    timestamptz,
  ADD COLUMN voided_by    uuid,
  ADD COLUMN void_reason  text;
COMMENT ON COLUMN public.training_records.voided_at IS
  'W2-12: a wrong record is voided (with reason) and re-recorded, never edited.';

ALTER TABLE public.designations
  ADD COLUMN appointed_by uuid,
  ADD COLUMN ended_by     uuid,
  ADD COLUMN end_reason   text;

-- ---------- 2. guard triggers ----------
CREATE OR REPLACE FUNCTION public.trg_controlled_document_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.client_org_id IS DISTINCT FROM OLD.client_org_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'controlled document identity columns are immutable';
  END IF;
  IF OLD.status IN ('superseded','withdrawn') THEN
    RAISE EXCEPTION 'document % v% is % — frozen history (NFR-09)',
      OLD.reference, OLD.version, OLD.status;
  END IF;
  IF OLD.status = 'issued' THEN
    IF NEW.reference IS DISTINCT FROM OLD.reference
       OR NEW.title IS DISTINCT FROM OLD.title
       OR NEW.version IS DISTINCT FROM OLD.version
       OR NEW.owner IS DISTINCT FROM OLD.owner
       OR NEW.approval_date IS DISTINCT FROM OLD.approval_date
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.issued_by IS DISTINCT FROM OLD.issued_by THEN
      RAISE EXCEPTION 'issued document versions are immutable (NFR-09) — register a new version';
    END IF;
    IF NEW.status NOT IN ('issued','superseded','withdrawn') THEN
      RAISE EXCEPTION 'an issued document cannot return to %', NEW.status;
    END IF;
  ELSE  -- draft
    IF NEW.status = 'superseded' THEN
      RAISE EXCEPTION 'only an issued version can be superseded';
    END IF;
    IF NEW.status = 'issued' AND (NEW.approval_date IS NULL OR NEW.issued_at IS NULL) THEN
      RAISE EXCEPTION 'issuing requires an approval date and an issue stamp';
    END IF;
  END IF;
  IF NEW.status = 'withdrawn' AND NEW.withdrawn_at IS NULL THEN
    RAISE EXCEPTION 'withdrawal must be stamped';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER controlled_document_guard
  BEFORE UPDATE ON public.controlled_documents
  FOR EACH ROW EXECUTE FUNCTION public.trg_controlled_document_guard();

CREATE OR REPLACE FUNCTION public.trg_training_record_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'training record is voided — frozen';
  END IF;
  IF NEW.voided_at IS NULL
     OR (to_jsonb(NEW) - ARRAY['voided_at','voided_by','void_reason'])
        IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['voided_at','voided_by','void_reason']) THEN
    RAISE EXCEPTION 'training records are not edited — void and re-record';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER training_record_guard
  BEFORE UPDATE ON public.training_records
  FOR EACH ROW EXECUTE FUNCTION public.trg_training_record_guard();

CREATE OR REPLACE FUNCTION public.trg_designation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.client_org_id IS DISTINCT FROM OLD.client_org_id
     OR NEW.role IS DISTINCT FROM OLD.role
     OR NEW.person IS DISTINCT FROM OLD.person
     OR NEW.date_designated IS DISTINCT FROM OLD.date_designated
     OR NEW.appointed_by IS DISTINCT FROM OLD.appointed_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'designation identity is immutable — end it and appoint anew';
  END IF;
  IF OLD.end_date IS NOT NULL THEN
    RAISE EXCEPTION 'designation has ended — history is frozen';
  END IF;
  IF OLD.evidence_document_id IS NOT NULL
     AND NEW.evidence_document_id IS DISTINCT FROM OLD.evidence_document_id THEN
    RAISE EXCEPTION 'appointment evidence is already attached';
  END IF;
  IF OLD.registration_ref IS NOT NULL
     AND NEW.registration_ref IS DISTINCT FROM OLD.registration_ref THEN
    RAISE EXCEPTION 'registration reference is already recorded';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER designation_guard
  BEFORE UPDATE ON public.designations
  FOR EACH ROW EXECUTE FUNCTION public.trg_designation_guard();

-- ---------- 3. close the direct write paths ----------
REVOKE INSERT, UPDATE, DELETE ON public.controlled_documents FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.controlled_document_activities FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.training_records FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.designations FROM authenticated;
DROP POLICY IF EXISTS designations_write ON public.designations;

-- ---------- 4. holds_designation: end_date exclusive ----------
CREATE OR REPLACE FUNCTION public.holds_designation(p_client_org uuid, p_kinds text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.designations d
                  WHERE d.client_org_id = p_client_org
                    AND d.person = auth.uid()
                    AND d.role = ANY(p_kinds)
                    AND d.date_designated <= CURRENT_DATE
                    AND (d.end_date IS NULL OR d.end_date > CURRENT_DATE))
$$;
COMMENT ON FUNCTION public.holds_designation(uuid, text[]) IS
  'W2-12: caller holds a LIVE designation of one of p_kinds on this client '
  '(date_designated <= today < end_date-or-NULL; end_date EXCLUSIVE like '
  'role_assignments). Column probe dropped — public.designations is fixed.';

-- ---------- 5. helpers ----------
CREATE OR REPLACE FUNCTION public.client_practice(p_client_org uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT practice_id FROM public.client_orgs WHERE id = p_client_org
$$;

-- read gate for the client-level records: the client is visible
-- (allowed_client_orgs) OR the caller holds any active role reaching it
-- (programme-scope client roles are not in allowed_client_orgs).
CREATE OR REPLACE FUNCTION public.can_read_client_records(p_client_org uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_client_org IN (SELECT public.allowed_client_orgs())
      OR public.has_client_role(p_client_org,
           ARRAY['partner_admin','partner_consultant','read_only',
                 'executive','accountable_officer','programme_lead',
                 'workstream_lead','external_provider','assessor',
                 'client_admin','client_contributor'])
$$;

-- D4: may p_person hold p_role on p_client_org?
CREATE OR REPLACE FUNCTION public.designation_eligible(p_client_org uuid, p_role text, p_person uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH holders AS (
    SELECT coalesce(
      (SELECT jp.role_labels -> 'designation_holders' -> p_role
         FROM public.client_orgs c JOIN public.jurisdiction_packs jp ON jp.code = c.jurisdiction
        WHERE c.id = p_client_org
          AND jsonb_typeof(jp.role_labels -> 'designation_holders' -> p_role) = 'array'),
      '["client"]'::jsonb) AS levels)
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments ra, holders h
     WHERE ra.user_id = p_person
       AND ra.start_date <= CURRENT_DATE
       AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
       AND h.levels ? ra.level
       AND ( (ra.level = 'client' AND (
                (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
             OR (ra.scope_type = 'programme' AND ra.scope_id IN
                   (SELECT p.id FROM public.programmes p WHERE p.client_org_id = p_client_org))))
          OR (ra.level = 'partner' AND (
                (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
             OR (ra.scope_type = 'partner' AND ra.scope_id = public.client_practice(p_client_org))))))
$$;

-- ============================================================================
-- 6. CONTROLLED DOCUMENT RPCs
-- ============================================================================
CREATE OR REPLACE FUNCTION public.register_controlled_document(
    p_client_org_id uuid, p_reference text, p_title text, p_version text,
    p_owner text DEFAULT NULL, p_approval_date date DEFAULT NULL,
    p_next_review_date date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_ref text := btrim(p_reference); v_ver text := btrim(p_version);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.client_orgs WHERE id = p_client_org_id) THEN
    RAISE EXCEPTION 'client % not found', p_client_org_id;
  END IF;
  IF NOT public.has_client_role(p_client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'registering a document requires a document write role (FR-DOC-01)';
  END IF;
  IF v_ref IS NULL OR v_ref = '' OR p_title IS NULL OR btrim(p_title) = ''
     OR v_ver IS NULL OR v_ver = '' THEN
    RAISE EXCEPTION 'reference, title and version are required';
  END IF;
  IF p_approval_date IS NOT NULL AND p_next_review_date IS NOT NULL
     AND p_next_review_date <= p_approval_date THEN
    RAISE EXCEPTION 'next review date must fall after the approval date';
  END IF;
  -- serialise versions of one reference
  PERFORM 1 FROM public.client_orgs WHERE id = p_client_org_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.controlled_documents
              WHERE client_org_id = p_client_org_id AND reference = v_ref AND version = v_ver) THEN
    RAISE EXCEPTION 'document % version % already exists', v_ref, v_ver;
  END IF;
  IF EXISTS (SELECT 1 FROM public.controlled_documents
              WHERE client_org_id = p_client_org_id AND reference = v_ref AND status = 'draft') THEN
    RAISE EXCEPTION 'document % already has an open draft — edit or withdraw it first', v_ref;
  END IF;

  INSERT INTO public.controlled_documents
      (client_org_id, reference, title, version, owner, approval_date,
       next_review_date, created_by)
  VALUES (p_client_org_id, v_ref, btrim(p_title), v_ver, NULLIF(btrim(p_owner), ''),
          p_approval_date, p_next_review_date, auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(p_client_org_id), 'controlled_document.registered',
          jsonb_build_object('controlled_document_id', v_id, 'client_org_id', p_client_org_id,
                             'reference', v_ref, 'version', v_ver));
  RETURN v_id;
END $$;

-- patch a DRAFT: NULL = unchanged; owner '' clears it
CREATE OR REPLACE FUNCTION public.update_controlled_document(
    p_document_id uuid, p_title text DEFAULT NULL, p_owner text DEFAULT NULL,
    p_version text DEFAULT NULL, p_approval_date date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'editing a document requires a document write role (FR-DOC-01)';
  END IF;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'document % v% is % — register a new version instead (NFR-09)',
      v_doc.reference, v_doc.version, v_doc.status;
  END IF;
  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN RAISE EXCEPTION 'title cannot be blank'; END IF;
  IF p_version IS NOT NULL AND btrim(p_version) = '' THEN RAISE EXCEPTION 'version cannot be blank'; END IF;
  IF p_version IS NOT NULL AND btrim(p_version) <> v_doc.version AND EXISTS (
       SELECT 1 FROM public.controlled_documents
        WHERE client_org_id = v_doc.client_org_id AND reference = v_doc.reference
          AND version = btrim(p_version)) THEN
    RAISE EXCEPTION 'document % version % already exists', v_doc.reference, btrim(p_version);
  END IF;
  IF coalesce(p_approval_date, v_doc.approval_date) IS NOT NULL AND v_doc.next_review_date IS NOT NULL
     AND v_doc.next_review_date <= coalesce(p_approval_date, v_doc.approval_date) THEN
    RAISE EXCEPTION 'next review date must fall after the approval date';
  END IF;

  UPDATE public.controlled_documents
     SET title = coalesce(btrim(p_title), title),
         owner = CASE WHEN p_owner IS NULL THEN owner ELSE NULLIF(btrim(p_owner), '') END,
         version = coalesce(btrim(p_version), version),
         approval_date = coalesce(p_approval_date, approval_date)
   WHERE id = p_document_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.updated',
          jsonb_build_object('controlled_document_id', p_document_id, 'reference', v_doc.reference,
                             'title', p_title, 'owner', p_owner, 'version', p_version,
                             'approval_date', p_approval_date));
  RETURN p_document_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_document_review_date(
    p_document_id uuid, p_next_review_date date)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'setting a review date requires a document write role (FR-DOC-01)';
  END IF;
  IF v_doc.status NOT IN ('draft','issued') THEN
    RAISE EXCEPTION 'document % v% is % — no review date on history', v_doc.reference,
      v_doc.version, v_doc.status;
  END IF;
  IF p_next_review_date IS NOT NULL AND v_doc.approval_date IS NOT NULL
     AND p_next_review_date <= v_doc.approval_date THEN
    RAISE EXCEPTION 'next review date must fall after the approval date';
  END IF;

  UPDATE public.controlled_documents SET next_review_date = p_next_review_date
   WHERE id = p_document_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.review_date_set',
          jsonb_build_object('controlled_document_id', p_document_id, 'reference', v_doc.reference,
                             'from', v_doc.next_review_date, 'to', p_next_review_date));
  RETURN p_document_id;
END $$;

CREATE OR REPLACE FUNCTION public.link_document_activity(p_document_id uuid, p_activity_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents; v_act_client uuid; v_act_active boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'linking a document requires a document write role (FR-DOC-01)';
  END IF;
  IF v_doc.status NOT IN ('draft','issued') THEN
    RAISE EXCEPTION 'document % v% is % — links are frozen', v_doc.reference, v_doc.version, v_doc.status;
  END IF;
  SELECT p.client_org_id, a.active INTO v_act_client, v_act_active
    FROM public.activities a JOIN public.programmes p ON p.id = a.programme_id
   WHERE a.id = p_activity_id;
  IF v_act_client IS NULL THEN RAISE EXCEPTION 'activity % not found', p_activity_id; END IF;
  IF v_act_client <> v_doc.client_org_id THEN
    RAISE EXCEPTION 'activity belongs to another client';
  END IF;
  IF NOT v_act_active THEN RAISE EXCEPTION 'activity is retired'; END IF;

  INSERT INTO public.controlled_document_activities (controlled_document_id, activity_id)
  VALUES (p_document_id, p_activity_id) ON CONFLICT DO NOTHING;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.linked',
          jsonb_build_object('controlled_document_id', p_document_id, 'activity_id', p_activity_id));
  RETURN p_document_id;
END $$;

CREATE OR REPLACE FUNCTION public.unlink_document_activity(p_document_id uuid, p_activity_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'unlinking a document requires a document write role (FR-DOC-01)';
  END IF;
  IF v_doc.status NOT IN ('draft','issued') THEN
    RAISE EXCEPTION 'document % v% is % — links are frozen', v_doc.reference, v_doc.version, v_doc.status;
  END IF;
  DELETE FROM public.controlled_document_activities
   WHERE controlled_document_id = p_document_id AND activity_id = p_activity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'activity is not linked to this document'; END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.unlinked',
          jsonb_build_object('controlled_document_id', p_document_id, 'activity_id', p_activity_id));
  RETURN p_document_id;
END $$;

CREATE OR REPLACE FUNCTION public.issue_controlled_document(
    p_document_id uuid, p_approval_date date DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents; v_appr date; v_prev uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin',
              'accountable_officer']) THEN
    RAISE EXCEPTION 'issuing a document requires a document write role or the accountable officer (FR-DOC-01)';
  END IF;
  -- lock every version of the reference: one issue at a time
  PERFORM 1 FROM public.controlled_documents
    WHERE client_org_id = v_doc.client_org_id AND reference = v_doc.reference FOR UPDATE;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'document % v% is already % — only a draft can be issued',
      v_doc.reference, v_doc.version, v_doc.status;
  END IF;
  v_appr := coalesce(p_approval_date, v_doc.approval_date, CURRENT_DATE);
  IF v_appr > CURRENT_DATE THEN RAISE EXCEPTION 'approval date cannot be in the future'; END IF;
  IF v_doc.next_review_date IS NOT NULL AND v_doc.next_review_date <= v_appr THEN
    RAISE EXCEPTION 'next review date must fall after the approval date';
  END IF;

  UPDATE public.controlled_documents SET status = 'superseded'
   WHERE client_org_id = v_doc.client_org_id AND reference = v_doc.reference
     AND status = 'issued'
  RETURNING id INTO v_prev;

  UPDATE public.controlled_documents
     SET status = 'issued', approval_date = v_appr, issued_at = now(), issued_by = auth.uid()
   WHERE id = p_document_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.issued',
          jsonb_build_object('controlled_document_id', p_document_id, 'reference', v_doc.reference,
                             'version', v_doc.version, 'approval_date', v_appr,
                             'superseded_id', v_prev));
  RETURN p_document_id;
END $$;

CREATE OR REPLACE FUNCTION public.withdraw_controlled_document(
    p_document_id uuid, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_doc public.controlled_documents;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_doc FROM public.controlled_documents WHERE id = p_document_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'document % not found', p_document_id; END IF;
  IF NOT public.has_client_role(v_doc.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'withdrawing a document requires a document write role (FR-DOC-01)';
  END IF;
  IF v_doc.status NOT IN ('draft','issued') THEN
    RAISE EXCEPTION 'document % v% is already %', v_doc.reference, v_doc.version, v_doc.status;
  END IF;
  IF v_doc.status = 'issued' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'withdrawing an issued document needs a reason';
  END IF;

  UPDATE public.controlled_documents
     SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
         withdrawn_reason = NULLIF(btrim(p_reason), '')
   WHERE id = p_document_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_doc.client_org_id), 'controlled_document.withdrawn',
          jsonb_build_object('controlled_document_id', p_document_id, 'reference', v_doc.reference,
                             'version', v_doc.version, 'was', v_doc.status, 'reason', p_reason));
  RETURN p_document_id;
END $$;

-- register read: review_state from the server clock
--   overdue   next_review_date < today
--   due_soon  within p_due_within_days
--   ok / none
-- only draft + issued rows carry a review state (history is 'n/a').
CREATE OR REPLACE FUNCTION public.list_controlled_documents(
    p_client_org_id uuid, p_include_withdrawn boolean DEFAULT false,
    p_due_within_days int DEFAULT 30)
RETURNS TABLE (
    id uuid, reference text, title text, version text, owner text,
    approval_date date, next_review_date date, status text,
    issued_at timestamptz, issued_by uuid, withdrawn_at timestamptz,
    withdrawn_reason text, created_at timestamptz,
    review_state text, days_to_review int, today date, activities jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.can_read_client_records(p_client_org_id) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  RETURN QUERY
  SELECT d.id, d.reference, d.title, d.version, d.owner, d.approval_date,
         d.next_review_date, d.status, d.issued_at, d.issued_by, d.withdrawn_at,
         d.withdrawn_reason, d.created_at,
         CASE WHEN d.status NOT IN ('draft','issued') THEN 'n/a'
              WHEN d.next_review_date IS NULL THEN 'none'
              WHEN d.next_review_date < CURRENT_DATE THEN 'overdue'
              WHEN d.next_review_date <= CURRENT_DATE + greatest(coalesce(p_due_within_days, 30), 0)
                THEN 'due_soon'
              ELSE 'ok' END,
         (d.next_review_date - CURRENT_DATE)::int,
         CURRENT_DATE,
         coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'id', a.id, 'ref', a.ref, 'text', a.text,
                     'programme_id', a.programme_id, 'active', a.active,
                     'status', a.status) ORDER BY a.ref)
                     FROM public.controlled_document_activities l
                     JOIN public.activities a ON a.id = l.activity_id
                    WHERE l.controlled_document_id = d.id), '[]'::jsonb)
    FROM public.controlled_documents d
   WHERE d.client_org_id = p_client_org_id
     AND (p_include_withdrawn OR d.status <> 'withdrawn')
   ORDER BY d.reference, d.created_at DESC;
END $$;

-- ============================================================================
-- 7. TRAINING RPCs
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_training(
    p_client_org_id uuid, p_person text, p_session text, p_date date,
    p_attendance boolean DEFAULT true, p_site text DEFAULT NULL,
    p_functional_group text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.client_orgs WHERE id = p_client_org_id) THEN
    RAISE EXCEPTION 'client % not found', p_client_org_id;
  END IF;
  IF NOT public.has_client_role(p_client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'recording training requires a training write role (FR-TRN-01)';
  END IF;
  IF p_person IS NULL OR btrim(p_person) = '' OR p_session IS NULL OR btrim(p_session) = '' THEN
    RAISE EXCEPTION 'person and course are required';
  END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'training date is required'; END IF;
  IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'training date cannot be in the future'; END IF;
  IF EXISTS (SELECT 1 FROM public.training_records t
              WHERE t.client_org_id = p_client_org_id AND t.voided_at IS NULL
                AND lower(btrim(t.person)) = lower(btrim(p_person))
                AND lower(btrim(t.session)) = lower(btrim(p_session))
                AND t.date = p_date) THEN
    RAISE EXCEPTION '% already has a record for % on %', btrim(p_person), btrim(p_session), p_date;
  END IF;

  INSERT INTO public.training_records
      (client_org_id, person, site, functional_group, session, date, attendance, recorded_by)
  VALUES (p_client_org_id, btrim(p_person), NULLIF(btrim(p_site), ''),
          NULLIF(btrim(p_functional_group), ''), btrim(p_session), p_date,
          coalesce(p_attendance, true), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(p_client_org_id), 'training_record.recorded',
          jsonb_build_object('training_record_id', v_id, 'client_org_id', p_client_org_id,
                             'session', btrim(p_session), 'date', p_date,
                             'attendance', coalesce(p_attendance, true)));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.void_training_record(p_record_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rec public.training_records;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_rec FROM public.training_records WHERE id = p_record_id FOR UPDATE;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'training record % not found', p_record_id; END IF;
  IF NOT public.has_client_role(v_rec.client_org_id,
        ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'voiding training requires a training write role (FR-TRN-01)';
  END IF;
  IF v_rec.voided_at IS NOT NULL THEN RAISE EXCEPTION 'training record is already voided'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a void reason is required'; END IF;

  UPDATE public.training_records
     SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   WHERE id = p_record_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_rec.client_org_id), 'training_record.voided',
          jsonb_build_object('training_record_id', p_record_id, 'reason', btrim(p_reason)));
  RETURN p_record_id;
END $$;

CREATE OR REPLACE FUNCTION public.list_training_records(
    p_client_org_id uuid, p_include_voided boolean DEFAULT false)
RETURNS TABLE (
    id uuid, person text, site text, functional_group text, session text,
    date date, attendance boolean, created_at timestamptz,
    voided_at timestamptz, void_reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.can_read_client_records(p_client_org_id) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  RETURN QUERY
  SELECT t.id, t.person, t.site, t.functional_group, t.session, t.date, t.attendance,
         t.created_at, t.voided_at, t.void_reason
    FROM public.training_records t
   WHERE t.client_org_id = p_client_org_id
     AND (p_include_voided OR t.voided_at IS NULL)
   ORDER BY t.date DESC NULLS LAST, t.person;
END $$;

-- ============================================================================
-- 8. DESIGNATION RPCs
-- ============================================================================
CREATE OR REPLACE FUNCTION public.appoint_designation(
    p_client_org_id uuid, p_role text, p_person uuid,
    p_date_designated date DEFAULT NULL, p_registration_ref text DEFAULT NULL,
    p_evidence_document_id uuid DEFAULT NULL, p_supersede_current boolean DEFAULT false)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_date date := coalesce(p_date_designated, CURRENT_DATE);
        v_cur public.designations;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.client_orgs WHERE id = p_client_org_id) THEN
    RAISE EXCEPTION 'client % not found', p_client_org_id;
  END IF;
  IF NOT public.has_client_role(p_client_org_id,
        ARRAY['partner_admin','partner_consultant','accountable_officer']) THEN
    RAISE EXCEPTION 'appointing a designation requires partner_admin, partner_consultant or the accountable officer (FR-ACC-03)';
  END IF;
  IF p_role IS NULL OR p_role NOT IN
       ('information_officer','deputy_information_officer','dpo','named_alternate') THEN
    RAISE EXCEPTION 'unknown designation %', p_role;
  END IF;
  IF p_person IS NULL OR NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_person) THEN
    RAISE EXCEPTION 'designee must be a known user';
  END IF;
  IF p_person = auth.uid() THEN
    RAISE EXCEPTION 'nobody may appoint themselves to a designation';
  END IF;
  IF NOT public.designation_eligible(p_client_org_id, p_role, p_person) THEN
    RAISE EXCEPTION 'designee is not eligible to hold % for this client (jurisdiction pack rule, FR-ACC-03)', p_role;
  END IF;
  IF v_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'designation date cannot be in the future';
  END IF;
  IF p_evidence_document_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.documents WHERE id = p_evidence_document_id
          AND client_org_id = p_client_org_id) THEN
    RAISE EXCEPTION 'evidence document not found for this client';
  END IF;

  -- serialise appointments per client
  PERFORM 1 FROM public.client_orgs WHERE id = p_client_org_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.designations
              WHERE client_org_id = p_client_org_id AND role = p_role
                AND person = p_person AND end_date IS NULL) THEN
    RAISE EXCEPTION 'this person already holds % for this client', p_role;
  END IF;
  IF p_role = 'information_officer' THEN
    SELECT * INTO v_cur FROM public.designations
     WHERE client_org_id = p_client_org_id AND role = 'information_officer' AND end_date IS NULL
     LIMIT 1;
    IF v_cur.id IS NOT NULL THEN
      IF NOT coalesce(p_supersede_current, false) THEN
        RAISE EXCEPTION 'the client already has a current information officer — confirm succession to replace them';
      END IF;
      IF v_date < v_cur.date_designated THEN
        RAISE EXCEPTION 'a successor cannot be designated before the current holder';
      END IF;
      UPDATE public.designations
         SET end_date = greatest(CURRENT_DATE, date_designated), ended_by = auth.uid(),
             end_reason = 'succeeded'
       WHERE id = v_cur.id;
      INSERT INTO public.audit_log (user_id, practice_id, action, detail)
      VALUES (auth.uid(), public.client_practice(p_client_org_id), 'designation.ended',
              jsonb_build_object('designation_id', v_cur.id, 'role', v_cur.role,
                                 'person', v_cur.person, 'reason', 'succeeded'));
    END IF;
  END IF;

  INSERT INTO public.designations
      (client_org_id, role, person, date_designated, evidence_document_id,
       registration_ref, appointed_by)
  VALUES (p_client_org_id, p_role, p_person, v_date, p_evidence_document_id,
          NULLIF(btrim(p_registration_ref), ''), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(p_client_org_id), 'designation.appointed',
          jsonb_build_object('designation_id', v_id, 'client_org_id', p_client_org_id,
                             'role', p_role, 'person', p_person, 'date_designated', v_date,
                             'evidence_document_id', p_evidence_document_id));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.end_designation(p_designation_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_d public.designations;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_d FROM public.designations WHERE id = p_designation_id FOR UPDATE;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'designation % not found', p_designation_id; END IF;
  IF NOT public.has_client_role(v_d.client_org_id,
        ARRAY['partner_admin','partner_consultant','accountable_officer']) THEN
    RAISE EXCEPTION 'ending a designation requires partner_admin, partner_consultant or the accountable officer (FR-ACC-03)';
  END IF;
  IF v_d.end_date IS NOT NULL THEN
    RAISE EXCEPTION 'designation already ended on %', v_d.end_date;
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN RAISE EXCEPTION 'a reason is required'; END IF;

  UPDATE public.designations
     SET end_date = greatest(CURRENT_DATE, date_designated), ended_by = auth.uid(),
         end_reason = btrim(p_reason)
   WHERE id = p_designation_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_d.client_org_id), 'designation.ended',
          jsonb_build_object('designation_id', p_designation_id, 'role', v_d.role,
                             'person', v_d.person, 'reason', btrim(p_reason)));
  RETURN p_designation_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_designation_evidence(
    p_designation_id uuid, p_evidence_document_id uuid DEFAULT NULL,
    p_registration_ref text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_d public.designations;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_d FROM public.designations WHERE id = p_designation_id FOR UPDATE;
  IF v_d.id IS NULL THEN RAISE EXCEPTION 'designation % not found', p_designation_id; END IF;
  IF NOT public.has_client_role(v_d.client_org_id,
        ARRAY['partner_admin','partner_consultant','accountable_officer']) THEN
    RAISE EXCEPTION 'recording designation evidence requires partner_admin, partner_consultant or the accountable officer (FR-ACC-03)';
  END IF;
  IF v_d.end_date IS NOT NULL THEN RAISE EXCEPTION 'designation has ended — history is frozen'; END IF;
  IF p_evidence_document_id IS NULL AND (p_registration_ref IS NULL OR btrim(p_registration_ref) = '') THEN
    RAISE EXCEPTION 'nothing to record';
  END IF;
  IF p_evidence_document_id IS NOT NULL THEN
    IF v_d.evidence_document_id IS NOT NULL THEN
      RAISE EXCEPTION 'appointment evidence is already attached';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.documents WHERE id = p_evidence_document_id
                      AND client_org_id = v_d.client_org_id) THEN
      RAISE EXCEPTION 'evidence document not found for this client';
    END IF;
  END IF;
  IF p_registration_ref IS NOT NULL AND btrim(p_registration_ref) <> ''
     AND v_d.registration_ref IS NOT NULL THEN
    RAISE EXCEPTION 'registration reference is already recorded';
  END IF;

  UPDATE public.designations
     SET evidence_document_id = coalesce(p_evidence_document_id, evidence_document_id),
         registration_ref = coalesce(NULLIF(btrim(p_registration_ref), ''), registration_ref)
   WHERE id = p_designation_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.client_practice(v_d.client_org_id), 'designation.evidence_recorded',
          jsonb_build_object('designation_id', p_designation_id,
                             'evidence_document_id', p_evidence_document_id,
                             'registration_ref', NULLIF(btrim(p_registration_ref), '')));
  RETURN p_designation_id;
END $$;

CREATE OR REPLACE FUNCTION public.list_designations(p_client_org_id uuid)
RETURNS TABLE (
    id uuid, role text, person uuid, person_name text, person_email text,
    date_designated date, end_date date, is_current boolean,
    registration_ref text, evidence_document_id uuid, evidence_filename text,
    appointed_by uuid, appointed_by_name text, ended_by_name text,
    end_reason text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.can_read_client_records(p_client_org_id) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  RETURN QUERY
  SELECT d.id, d.role, d.person,
         coalesce(NULLIF(btrim(u.full_name), ''), split_part(u.email, '@', 1)),
         u.email, d.date_designated, d.end_date,
         (d.date_designated <= CURRENT_DATE AND (d.end_date IS NULL OR d.end_date > CURRENT_DATE)),
         d.registration_ref, d.evidence_document_id, doc.original_filename,
         d.appointed_by,
         coalesce(NULLIF(btrim(ua.full_name), ''), split_part(ua.email, '@', 1)),
         coalesce(NULLIF(btrim(ue.full_name), ''), split_part(ue.email, '@', 1)),
         d.end_reason, d.created_at
    FROM public.designations d
    LEFT JOIN public.users u  ON u.id = d.person
    LEFT JOIN public.users ua ON ua.id = d.appointed_by
    LEFT JOIN public.users ue ON ue.id = d.ended_by
    LEFT JOIN public.documents doc ON doc.id = d.evidence_document_id
   WHERE d.client_org_id = p_client_org_id
   ORDER BY d.role, (d.end_date IS NULL) DESC, d.date_designated DESC, d.created_at DESC;
END $$;

CREATE OR REPLACE FUNCTION public.designation_candidates(p_client_org_id uuid, p_role text)
RETURNS TABLE (id uuid, name text, email text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT public.has_client_role(p_client_org_id,
        ARRAY['partner_admin','partner_consultant','accountable_officer']) THEN
    RAISE EXCEPTION 'listing designation candidates requires an appointing role';
  END IF;
  RETURN QUERY
  SELECT u.id, coalesce(NULLIF(btrim(u.full_name), ''), split_part(u.email, '@', 1)), u.email
    FROM public.users u
   WHERE u.id <> auth.uid()
     AND public.designation_eligible(p_client_org_id, p_role, u.id)
   ORDER BY 2;
END $$;

-- ---------- 9. execution surface ----------
REVOKE EXECUTE ON FUNCTION
  public.trg_controlled_document_guard(),
  public.trg_training_record_guard(),
  public.trg_designation_guard(),
  public.client_practice(uuid),
  public.can_read_client_records(uuid),
  public.designation_eligible(uuid, text, uuid),
  public.register_controlled_document(uuid, text, text, text, text, date, date),
  public.update_controlled_document(uuid, text, text, text, date),
  public.set_document_review_date(uuid, date),
  public.link_document_activity(uuid, uuid),
  public.unlink_document_activity(uuid, uuid),
  public.issue_controlled_document(uuid, date),
  public.withdraw_controlled_document(uuid, text),
  public.list_controlled_documents(uuid, boolean, int),
  public.record_training(uuid, text, text, date, boolean, text, text),
  public.void_training_record(uuid, text),
  public.list_training_records(uuid, boolean),
  public.appoint_designation(uuid, text, uuid, date, text, uuid, boolean),
  public.end_designation(uuid, text),
  public.set_designation_evidence(uuid, uuid, text),
  public.list_designations(uuid),
  public.designation_candidates(uuid, text)
FROM anon, public;

GRANT EXECUTE ON FUNCTION
  public.can_read_client_records(uuid),
  public.register_controlled_document(uuid, text, text, text, text, date, date),
  public.update_controlled_document(uuid, text, text, text, date),
  public.set_document_review_date(uuid, date),
  public.link_document_activity(uuid, uuid),
  public.unlink_document_activity(uuid, uuid),
  public.issue_controlled_document(uuid, date),
  public.withdraw_controlled_document(uuid, text),
  public.list_controlled_documents(uuid, boolean, int),
  public.record_training(uuid, text, text, date, boolean, text, text),
  public.void_training_record(uuid, text),
  public.list_training_records(uuid, boolean),
  public.appoint_designation(uuid, text, uuid, date, text, uuid, boolean),
  public.end_designation(uuid, text),
  public.set_designation_evidence(uuid, uuid, text),
  public.list_designations(uuid),
  public.designation_candidates(uuid, text)
TO authenticated;

COMMIT;
