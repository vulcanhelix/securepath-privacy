-- Delete a document ONLY while it is still junk: never confirmed into a checklist slot,
-- not part of a version-history chain, not referenced as task evidence. Everything that
-- has become evidence stays immutable — corrections are new versions via record_document
-- (p_supersedes), never deletes.
--
-- SECURITY DEFINER bypasses the REVOKE DELETE on documents, so every guard must live in
-- this body (same lesson as 20260810000001).

CREATE FUNCTION public.delete_document(p_document_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_client uuid; v_path text; v_name text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT client_org_id, storage_path, original_filename INTO v_client, v_path, v_name
    FROM documents WHERE id = p_document_id;
  IF v_client IS NULL THEN RAISE EXCEPTION 'document not found'; END IF;
  IF v_client NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to document';
  END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot delete'; END IF;

  IF EXISTS (SELECT 1 FROM document_links WHERE document_id = p_document_id AND status = 'confirmed') THEN
    RAISE EXCEPTION 'document is confirmed evidence — replace it with a new version instead';
  END IF;
  IF EXISTS (SELECT 1 FROM documents WHERE supersedes = p_document_id) THEN
    RAISE EXCEPTION 'document is part of a version history and cannot be deleted';
  END IF;
  IF EXISTS (SELECT 1 FROM tasks WHERE evidence_document_id = p_document_id) THEN
    RAISE EXCEPTION 'document is task evidence and cannot be deleted';
  END IF;

  DELETE FROM documents WHERE id = p_document_id;   -- proposed/rejected links cascade

  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'document.deleted',
            jsonb_build_object('document_id', p_document_id, 'client_org_id', v_client,
                               'filename', v_name));
  RETURN v_path;   -- caller (Next API route) removes the object from storage
END $$;

REVOKE ALL ON FUNCTION public.delete_document(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_document(uuid) TO authenticated;
