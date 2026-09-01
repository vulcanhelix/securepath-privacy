-- documents.source: mark where an evidence document came from. Uploads vs system-issued
-- artifacts were previously indistinguishable — the monthly report's "documents issued this
-- period" had to guess by created_at month over ALL documents. The assessment report's
-- "documentation issued" section needs the truth. source_id points at the issuing artifact row.

BEGIN;

ALTER TABLE public.documents
  ADD COLUMN source    text NOT NULL DEFAULT 'upload'
    CHECK (source IN ('upload','policy','manual','monthly_report','assessment_report')),
  ADD COLUMN source_id uuid;

CREATE INDEX idx_documents_source ON public.documents (client_org_id, source);

-- best-effort backfill from the established storage-key conventions
UPDATE public.documents SET source = 'policy'
  WHERE storage_path ~ '/policy-[0-9a-f-]{36}-v[0-9]+\.md$';
UPDATE public.documents SET source = 'manual'
  WHERE storage_path ~ '/manual-[0-9a-f-]{36}-v[0-9]+\.md$';
UPDATE public.documents SET source = 'monthly_report'
  WHERE storage_path ~ '/report-[0-9]{4}-[0-9]{2}-';

-- link source_id back where the artifact id is embedded in the key
UPDATE public.documents d SET source_id = p.id FROM public.policies p
  WHERE d.source = 'policy' AND d.storage_path LIKE '%/policy-' || p.id || '-v%';
UPDATE public.documents d SET source_id = m.id FROM public.manuals m
  WHERE d.source = 'manual' AND d.storage_path LIKE '%/manual-' || m.id || '-v%';

-- ---------- re-create the three issue RPCs to stamp source/source_id ----------
-- Bodies unchanged apart from the documents INSERT column list. Every guard line kept.

CREATE OR REPLACE FUNCTION public.issue_policy(
    p_policy_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v policies%ROWTYPE; did uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM policies WHERE id = p_policy_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'policy not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to policy'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'not permitted to issue policies';
  END IF;
  IF v.approval_status <> 'approved' THEN RAISE EXCEPTION 'only an approved policy can be issued'; END IF;

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by, source, source_id)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid(), 'policy', p_policy_id)
    RETURNING id INTO did;

  IF v.checklist_id IS NOT NULL THEN
    INSERT INTO document_links (client_org_id, checklist_id, document_id, status, linked_by)
      VALUES (v.client_org_id, v.checklist_id, did, 'confirmed', auth.uid())
      ON CONFLICT (checklist_id, document_id) DO UPDATE SET status = 'confirmed';
  END IF;

  UPDATE policies SET approval_status = 'issued', updated_at = now() WHERE id = p_policy_id;
  PERFORM public.record_approval('policy', p_policy_id, 'issued', 'Policy issued as evidence document');
  RETURN did;
END $$;

CREATE OR REPLACE FUNCTION public.sign_off_manual(p_manual_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
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

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by, source, source_id)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid(), 'manual', p_manual_id)
    RETURNING id INTO did;
  UPDATE manuals SET approval_status = 'issued', s51_published = true, updated_at = now() WHERE id = p_manual_id;
  PERFORM public.record_approval('manual', p_manual_id, 'issued', 'Gate 3: IO sign-off, PAIA s.51 published');
  IF v.track_id IS NOT NULL THEN
    PERFORM public.advance_track_stage(v.track_id, 5, 'Gate 3: PIMS manual signed off and s.51 published');
  END IF;
  RETURN did;
END $$;

CREATE OR REPLACE FUNCTION public.issue_monthly_report(p_report_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v monthly_reports%ROWTYPE; did uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM monthly_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'only advisors or the client admin may issue the report';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN RAISE EXCEPTION 'report already issued'; END IF;

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by, source, source_id)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid(), 'monthly_report', p_report_id)
    RETURNING id INTO did;
  UPDATE monthly_reports SET approval_status = 'issued', updated_at = now() WHERE id = p_report_id;
  PERFORM public.record_approval('monthly_report', p_report_id, 'issued', 'Monthly report issued: ' || v.period);
  RETURN did;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
