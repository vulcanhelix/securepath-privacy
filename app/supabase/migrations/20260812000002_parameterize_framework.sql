-- ACCEPTANCE TEST fix: the only RPC that hardcoded the framework was
-- generate_remediation_plan (WHERE framework_key='popia'). Give it a framework argument so
-- the same task engine instantiates any framework's library. (The screen queries are
-- parameterized in the app; this is the one server-side constant.)

DROP FUNCTION IF EXISTS public.generate_remediation_plan(uuid);

CREATE FUNCTION public.generate_remediation_plan(p_client_org_id uuid, p_framework text DEFAULT 'popia')
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_track uuid; n int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to client organisation'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may generate the remediation plan';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM frameworks WHERE key = p_framework) THEN RAISE EXCEPTION 'unknown framework'; END IF;
  SELECT id INTO v_track FROM tracks
    WHERE client_org_id = p_client_org_id
      AND track_kind = (SELECT track_kind FROM frameworks WHERE key = p_framework);
  INSERT INTO tasks (client_org_id, track_id, template_id, theme, title, description, responsible, output, priority, created_by)
    SELECT p_client_org_id, v_track, t.id, t.theme, t.title, t.description, t.responsible, t.output, t.priority, auth.uid()
    FROM task_templates t
    WHERE t.framework_key = p_framework AND t.active
      AND NOT EXISTS (SELECT 1 FROM tasks x WHERE x.client_org_id = p_client_org_id AND x.template_id = t.id);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'remediation.generated',
            jsonb_build_object('client_org_id', p_client_org_id, 'framework', p_framework, 'tasks', n));
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION public.generate_remediation_plan(uuid, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.generate_remediation_plan(uuid, text) TO authenticated;
