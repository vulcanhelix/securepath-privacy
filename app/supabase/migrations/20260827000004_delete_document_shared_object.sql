-- Storage keys are content-addressed (client_org/sha256), so two document rows with
-- identical bytes share one physical object. Deleting a junk duplicate must not remove
-- the object while any other row still references it (Devin review, PR #6).
-- delete_document() now returns the storage path ONLY when no remaining row shares it;
-- the API route skips object deletion on NULL.

CREATE OR REPLACE FUNCTION public.delete_document(p_document_id uuid)
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

  -- another row (any client's duplicate within this bucket key scheme) still points at
  -- the same object: keep the bytes, tell the caller not to delete
  IF EXISTS (SELECT 1 FROM documents WHERE storage_path = v_path) THEN
    RETURN NULL;
  END IF;
  RETURN v_path;
END $$;

REVOKE ALL ON FUNCTION public.delete_document(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_document(uuid) TO authenticated;
