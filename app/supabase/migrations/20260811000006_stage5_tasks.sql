-- STAGE 5 — Implementation board. Content-driven, on the spine.
-- The remediation task library is CONTENT (task_templates, per framework, from SecurePath's
-- 6-phase POPIA framework). "Generate remediation plan" instantiates a client's tasks from it.
-- Gate 4 = remediation substantially complete (all critical + high done) → Stage 6.
-- Task evidence + magic-link task pages for client staff are the next increment.

BEGIN;

-- ---------- task library = content, per framework ----------
CREATE TABLE public.task_templates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_key  text NOT NULL REFERENCES public.frameworks(key),
    content_pack_id uuid REFERENCES public.content_packs(id),
    theme          text NOT NULL,               -- governance, registers, dsr, breach, operators, registrations, training, monitoring
    title          text NOT NULL,
    description    text,
    responsible    text,                         -- default owner role, e.g. 'Information Officer'
    timeframe      text,
    output         text,                         -- the evidence artifact this task produces
    priority       text NOT NULL CHECK (priority IN ('critical','high','medium','low')),
    sort           int NOT NULL DEFAULT 100,
    active         boolean NOT NULL DEFAULT true
);

-- ---------- tasks = instantiated per client ----------
CREATE TABLE public.tasks (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id      uuid REFERENCES public.tracks(id),
    template_id   uuid REFERENCES public.task_templates(id),
    theme         text NOT NULL,
    title         text NOT NULL,
    description   text,
    responsible   text,
    output        text,
    priority      text NOT NULL CHECK (priority IN ('critical','high','medium','low')),
    owner         text,                          -- assigned owner (free text for now; magic-link staff later)
    due_date      date,
    status        text NOT NULL DEFAULT 'todo' CHECK (status IN ('todo','in_progress','blocked','done')),
    evidence_document_id uuid REFERENCES public.documents(id),
    completed_at  timestamptz,
    created_by    uuid,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_tasks_client ON public.tasks (client_org_id, theme);

ALTER TABLE public.task_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY task_templates_read ON public.task_templates FOR SELECT TO authenticated USING (true);
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks FORCE ROW LEVEL SECURITY;
CREATE POLICY tasks_read ON public.tasks FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
REVOKE ALL ON public.task_templates, public.tasks FROM anon;
GRANT SELECT ON public.task_templates, public.tasks TO authenticated;

-- ---------- RPCs (guarded) ----------
-- instantiate the remediation plan from the task library (once); returns count created
CREATE FUNCTION public.generate_remediation_plan(p_client_org_id uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_track uuid; n int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to client organisation'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may generate the remediation plan';
  END IF;
  SELECT id INTO v_track FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = 'privacy';
  INSERT INTO tasks (client_org_id, track_id, template_id, theme, title, description, responsible, output, priority, created_by)
    SELECT p_client_org_id, v_track, t.id, t.theme, t.title, t.description, t.responsible, t.output, t.priority, auth.uid()
    FROM task_templates t
    WHERE t.framework_key = 'popia' AND t.active
      AND NOT EXISTS (SELECT 1 FROM tasks x WHERE x.client_org_id = p_client_org_id AND x.template_id = t.id);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'remediation.generated', jsonb_build_object('client_org_id', p_client_org_id, 'tasks', n));
  RETURN n;
END $$;

-- update a task (status / owner / due). Contributors may act on tasks too.
CREATE FUNCTION public.update_task(p_task_id uuid, p_status text, p_owner text, p_due date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v tasks%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'task not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to task'; END IF;
  IF public.current_role_name() = 'read_only' THEN RAISE EXCEPTION 'read_only cannot update tasks'; END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('todo','in_progress','blocked','done') THEN RAISE EXCEPTION 'bad status'; END IF;
  UPDATE tasks SET
    status = COALESCE(p_status, status),
    owner = COALESCE(p_owner, owner),
    due_date = COALESCE(p_due, due_date),
    completed_at = CASE WHEN p_status = 'done' THEN now()
                        WHEN p_status IS NOT NULL AND p_status <> 'done' THEN NULL
                        ELSE completed_at END,
    updated_at = now()
  WHERE id = p_task_id;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.generate_remediation_plan(uuid),
  public.update_task(uuid, text, text, date)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.generate_remediation_plan(uuid),
  public.update_task(uuid, text, text, date)
TO authenticated;

-- ---------- seed: POPIA remediation task library (from the 6-phase framework; privacy track) ----------
INSERT INTO public.task_templates (framework_key, content_pack_id, theme, title, responsible, timeframe, output, priority, sort)
SELECT 'popia', cp.id, x.theme, x.title, x.responsible, x.timeframe, x.output, x.priority, x.sort
FROM (SELECT id FROM public.content_packs WHERE practice_id IS NULL AND framework_key='popia' AND version=1) cp,
(VALUES
  ('governance','Appoint & register the Information Officer with the Regulator','Information Officer','Weeks 1–2','IR registration confirmation','critical',10),
  ('governance','Appoint Deputy Information Officer(s) where required','Information Officer','Weeks 1–3','Deputy appointment letter','medium',20),
  ('governance','Establish governance responsibilities & the risk register','Information Officer','Weeks 1–4','Risk register','high',30),
  ('registers','Build the Personal Information inventory','IO / Operations','Weeks 2–5','PI inventory','high',40),
  ('registers','Complete the Records of Processing Activities (ROPA)','Information Officer','Weeks 3–6','ROPA','high',50),
  ('registers','Build the Information Asset Register','IT','Weeks 2–5','Asset register','high',60),
  ('registers','Set retention periods & the disposal schedule','Information Officer','Weeks 4–6','Retention schedule','high',70),
  ('dsr','Stand up the Data Subject Request process & log','Information Officer','Weeks 4–6','DSR log operational','high',80),
  ('dsr','Publish the Data Subject Request form','Information Officer','Weeks 4–6','DSR form live','medium',90),
  ('breach','Establish the breach notification workflow (72h) & register','Information Officer','Weeks 5–7','Breach register + procedure','high',100),
  ('operators','Identify operators & issue Operator Agreements (DPAs)','IO / Legal','Weeks 6–10','Signed DPAs','high',110),
  ('operators','Assess cross-border transfers (s.72)','Information Officer','Weeks 6–10','Cross-border transfer assessment','medium',120),
  ('registrations','Publish the PAIA s.51 manual','Information Officer','Weeks 4–8','Published PAIA manual','critical',130),
  ('registrations','Submit the PAIA annual report (if required)','Information Officer','Annual','Submitted PAIA report','low',140),
  ('training','Deliver POPIA staff awareness training (100%)','HR','Weeks 10–16','Staff training log','medium',150),
  ('training','Train the Information Officer','Information Officer','Weeks 1–4','IO training certificate','medium',160),
  ('monitoring','Schedule the quarterly compliance review','Information Officer','Ongoing','Review calendar','low',170),
  ('monitoring','Establish the annual PIMS audit','Information Officer','Annual','Audit report','medium',180)
) AS x(theme,title,responsible,timeframe,output,priority,sort);

COMMIT;
