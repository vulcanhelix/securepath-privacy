-- STAGE 3 close-the-loop + GATE 2. Approving a policy is the gate event; ISSUING it turns
-- the approved policy into an immutable evidence document that fills its Stage-2 checklist
-- slot — so the gap map closes as the policy suite is built. Gate 2 (suite complete →
-- advance to Stage 4) stays an explicit advisor action, never a side effect.

-- issue_policy: called server-side AFTER the policy body is written to object storage
-- (the API route holds S3 creds). Inserts the evidence document, links it confirmed to the
-- policy's checklist slot, flips the policy to 'issued', logs the issue. One transaction.
CREATE FUNCTION public.issue_policy(
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

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid())
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

REVOKE EXECUTE ON FUNCTION public.issue_policy(uuid, text, text, bigint) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.issue_policy(uuid, text, text, bigint) TO authenticated;
