-- Conversational assessment transcript and evidence metadata.
CREATE TABLE IF NOT EXISTS public.assessment_chat_turns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.assessment_sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('assistant', 'user', 'system')),
  kind TEXT NOT NULL CHECK (kind IN ('question', 'answer', 'explainer', 'upload', 'summary', 'navigation', 'gap_details', 'owner', 'target_date', 'evidence')),
  content TEXT NOT NULL,
  question_id UUID REFERENCES public.assessment_questions(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);
ALTER TABLE public.assessment_chat_turns DROP CONSTRAINT IF EXISTS assessment_chat_turns_kind_check;
ALTER TABLE public.assessment_chat_turns ADD CONSTRAINT assessment_chat_turns_kind_check
  CHECK (kind IN ('question', 'answer', 'explainer', 'upload', 'summary', 'navigation', 'gap_details', 'owner', 'target_date', 'evidence'));

CREATE TABLE IF NOT EXISTS public.assessment_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_org_id UUID NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
  session_id UUID NOT NULL REFERENCES public.assessment_sessions(id) ON DELETE CASCADE,
  question_id UUID REFERENCES public.assessment_questions(id) ON DELETE SET NULL,
  original_filename TEXT NOT NULL,
  mime TEXT NOT NULL,
  size BIGINT NOT NULL CHECK (size > 0),
  sha256 TEXT NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path TEXT NOT NULL UNIQUE,
  uploaded_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_assessment_chat_turns_session_created
  ON public.assessment_chat_turns(session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_assessment_documents_session
  ON public.assessment_documents(session_id, created_at);

ALTER TABLE public.assessment_chat_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_chat_turns FORCE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_documents FORCE ROW LEVEL SECURITY;

CREATE POLICY assessment_chat_turns_read ON public.assessment_chat_turns
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.assessment_sessions s
    WHERE s.id = assessment_chat_turns.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
  ));
CREATE POLICY assessment_chat_turns_append ON public.assessment_chat_turns
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.assessment_sessions s
    WHERE s.id = assessment_chat_turns.session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
      AND public.current_role_name() <> 'read_only'
  ));

CREATE POLICY assessment_documents_read ON public.assessment_documents
  FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
CREATE POLICY assessment_documents_append ON public.assessment_documents
  FOR INSERT TO authenticated
  WITH CHECK (client_org_id IN (SELECT public.allowed_client_orgs())
    AND public.current_role_name() <> 'read_only'
    AND EXISTS (
      SELECT 1 FROM public.assessment_sessions s
      WHERE s.id = assessment_documents.session_id
        AND s.client_org_id = assessment_documents.client_org_id
    ));

REVOKE UPDATE, DELETE ON public.assessment_chat_turns FROM authenticated;
REVOKE UPDATE, DELETE ON public.assessment_documents FROM authenticated;

CREATE OR REPLACE FUNCTION public.append_assessment_chat_turn(
  p_session_id UUID, p_role TEXT, p_kind TEXT, p_content TEXT, p_question_id UUID DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE turn_id UUID;
BEGIN
  IF p_role NOT IN ('assistant', 'user', 'system') OR
     p_kind NOT IN ('question', 'answer', 'explainer', 'upload', 'summary', 'navigation', 'gap_details', 'owner', 'target_date', 'evidence') THEN
    RAISE EXCEPTION 'Invalid transcript turn';
  END IF;
  INSERT INTO public.assessment_chat_turns(session_id, role, kind, content, question_id, created_by)
  SELECT p_session_id, p_role, p_kind, p_content, p_question_id, auth.uid()
  WHERE EXISTS (
    SELECT 1 FROM public.assessment_sessions s
    WHERE s.id = p_session_id
      AND s.client_org_id IN (SELECT public.allowed_client_orgs())
      AND public.current_role_name() <> 'read_only'
  )
  RETURNING id INTO turn_id;
  IF turn_id IS NULL THEN RAISE EXCEPTION 'Assessment session not found or access denied'; END IF;
  INSERT INTO public.audit_log(user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.chat_turn_appended',
    jsonb_build_object('turn_id', turn_id, 'session_id', p_session_id, 'kind', p_kind));
  RETURN turn_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_assessment_chat_opening(p_session_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q RECORD;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_session_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.assessment_chat_turns WHERE session_id = p_session_id) THEN RETURN; END IF;
  SELECT question, id INTO q
  FROM public.assessment_questions aq
  WHERE aq.framework = (SELECT framework FROM public.assessment_sessions WHERE id = p_session_id)
    AND aq.active
  ORDER BY section_id, question_number LIMIT 1;
  IF q.id IS NULL THEN RETURN; END IF;
  INSERT INTO public.assessment_chat_turns(session_id, role, kind, content, created_by)
  VALUES (p_session_id, 'assistant', 'question',
    'Welcome to your privacy assessment. I''ll guide you through each control conversationally. You can ask for an explanation or upload evidence at any time.',
    auth.uid());
  INSERT INTO public.assessment_chat_turns(session_id, role, kind, content, question_id, created_by)
  VALUES (p_session_id, 'assistant', 'question', q.question, q.id, auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.record_assessment_document(
  p_client_org_id UUID, p_session_id UUID, p_question_id UUID, p_original_filename TEXT,
  p_mime TEXT, p_size BIGINT, p_sha256 TEXT, p_storage_path TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE document_id UUID;
BEGIN
  IF p_size <= 0 OR p_size > 26214400 OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid evidence metadata';
  END IF;
  INSERT INTO public.assessment_documents(
    client_org_id, session_id, question_id, original_filename, mime, size, sha256, storage_path, uploaded_by
  )
  SELECT p_client_org_id, p_session_id, p_question_id, p_original_filename, p_mime, p_size, p_sha256, p_storage_path, auth.uid()
  WHERE p_client_org_id IN (SELECT public.allowed_client_orgs())
    AND public.current_role_name() <> 'read_only'
    AND EXISTS (SELECT 1 FROM public.assessment_sessions s
      WHERE s.id = p_session_id AND s.client_org_id = p_client_org_id)
  RETURNING id INTO document_id;
  IF document_id IS NULL THEN RAISE EXCEPTION 'Assessment session not found or access denied'; END IF;
  INSERT INTO public.audit_log(user_id, practice_id, action, detail)
  VALUES (auth.uid(), public.current_practice(), 'assessment.document_recorded',
    jsonb_build_object('document_id', document_id, 'session_id', p_session_id, 'question_id', p_question_id));
  RETURN document_id;
END;
$$;

GRANT SELECT ON public.assessment_chat_turns, public.assessment_documents TO authenticated;
GRANT EXECUTE ON FUNCTION public.append_assessment_chat_turn(UUID, TEXT, TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_assessment_document(UUID, UUID, UUID, TEXT, TEXT, BIGINT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_assessment_chat_opening(UUID) TO authenticated;
