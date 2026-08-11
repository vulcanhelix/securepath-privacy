-- STAGE 3 — Policy creation & approval. Content-driven, on the spine.
-- Policy templates are CONTENT (per framework, targeting a checklist slot). A policy is an
-- artifact carrying the shared approval_status; drafts are editable, approved/issued are
-- immutable (corrections = new version). Gate 2 (IO approves each policy) is the next
-- increment; this lays draft → edit → approve.

BEGIN;

-- ---------- policy templates = content, keyed to the checklist slot they draft ----------
CREATE TABLE public.policy_templates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_key  text NOT NULL REFERENCES public.frameworks(key),
    content_pack_id uuid REFERENCES public.content_packs(id),
    slot_key       text NOT NULL,            -- which checklist slot this template fills
    name           text NOT NULL,
    body           text NOT NULL,            -- markdown with [PLACEHOLDER] markers
    version        int NOT NULL DEFAULT 1,
    active         boolean NOT NULL DEFAULT true,
    UNIQUE (framework_key, slot_key, version)
);

-- ---------- policies = drafted artifacts, per client ----------
CREATE TABLE public.policies (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id   uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id        uuid REFERENCES public.tracks(id),
    checklist_id    uuid REFERENCES public.document_checklists(id),   -- the gap it fills
    template_id     uuid REFERENCES public.policy_templates(id),
    title           text NOT NULL,
    body            text NOT NULL DEFAULT '',
    approval_status public.approval_status NOT NULL DEFAULT 'draft_human',
    version         int NOT NULL DEFAULT 1,
    supersedes      uuid REFERENCES public.policies(id),
    created_by      uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_policies_client ON public.policies (client_org_id, created_at DESC);
CREATE INDEX idx_policy_templates_fw ON public.policy_templates (framework_key, slot_key);

-- ---------- RLS ----------
ALTER TABLE public.policy_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.policy_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY policy_templates_read ON public.policy_templates FOR SELECT TO authenticated USING (true);

ALTER TABLE public.policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.policies FORCE ROW LEVEL SECURITY;
CREATE POLICY policies_read ON public.policies FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));

REVOKE ALL ON public.policy_templates, public.policies FROM anon;
GRANT SELECT ON public.policy_templates, public.policies TO authenticated;

-- ---------- RPCs (SECURITY DEFINER, guarded — writes via these only) ----------
CREATE FUNCTION public.create_policy(
    p_client_org_id uuid, p_checklist_id uuid, p_template_id uuid, p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid; v_body text := ''; v_track uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to client organisation';
  END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'only advisors or the client admin may draft policies';
  END IF;
  IF p_template_id IS NOT NULL THEN SELECT body INTO v_body FROM policy_templates WHERE id = p_template_id; END IF;
  SELECT id INTO v_track FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = 'privacy';
  INSERT INTO policies (client_org_id, track_id, checklist_id, template_id, title, body, created_by)
    VALUES (p_client_org_id, v_track, p_checklist_id, p_template_id, p_title, COALESCE(v_body,''), auth.uid())
    RETURNING id INTO pid;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'policy.drafted',
            jsonb_build_object('policy_id', pid, 'client_org_id', p_client_org_id));
  RETURN pid;
END $$;

-- edit only while a draft (approved/issued are immutable — corrections are new versions)
CREATE FUNCTION public.update_policy_draft(p_policy_id uuid, p_title text, p_body text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v policies%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM policies WHERE id = p_policy_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'policy not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to policy'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'not permitted to edit policies';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN
    RAISE EXCEPTION 'policy is % — approved/issued policies are immutable, create a new version', v.approval_status;
  END IF;
  UPDATE policies SET title = COALESCE(p_title, title), body = COALESCE(p_body, body),
                      approval_status = 'draft_human', updated_at = now()
    WHERE id = p_policy_id;
END $$;

-- Gate 2 approval: IO (client_admin) or advisor approves this policy
CREATE FUNCTION public.approve_policy(p_policy_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v policies%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM policies WHERE id = p_policy_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'policy not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to policy'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'only advisors or the client admin may approve policies';
  END IF;
  IF v.approval_status = 'approved' THEN RAISE EXCEPTION 'policy already approved'; END IF;
  UPDATE policies SET approval_status = 'approved', updated_at = now() WHERE id = p_policy_id;
  PERFORM public.record_approval('policy', p_policy_id, 'approved', 'Gate 2 policy approval');
END $$;

REVOKE EXECUTE ON FUNCTION
  public.create_policy(uuid, uuid, uuid, text),
  public.update_policy_draft(uuid, text, text),
  public.approve_policy(uuid)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.create_policy(uuid, uuid, uuid, text),
  public.update_policy_draft(uuid, text, text),
  public.approve_policy(uuid)
TO authenticated;

-- ---------- seed: a few POPIA policy templates (STARTER skeletons — full library comes from
-- the PIM Generator content; these are structured placeholders William/PIM refines) ----------
INSERT INTO public.policy_templates (framework_key, content_pack_id, slot_key, name, body)
SELECT 'popia', cp.id, x.slot_key, x.name, x.body
FROM (SELECT id FROM public.content_packs WHERE practice_id IS NULL AND framework_key='popia' AND version=1) cp,
(VALUES
  ('privacy_policy','Privacy Policy (external)', E'# Privacy Policy\n\n**[ORGANISATION NAME]** ("we") is committed to protecting personal information in line with the Protection of Personal Information Act, 2013 (POPIA).\n\n## 1. Information Officer\nOur Information Officer is [IO NAME], contactable at [IO EMAIL].\n\n## 2. What we collect\n[List categories of personal information collected.]\n\n## 3. Why we process it\n[Purpose and lawful basis per POPIA s.11.]\n\n## 4. Sharing & operators\n[Third parties / operators, s.20-21.]\n\n## 5. Retention\nWe retain personal information per our Retention Schedule.\n\n## 6. Your rights\nYou may request access, correction or deletion by contacting our Information Officer.\n\n## 7. Security\n[Security safeguards, s.19.]\n\n_Approved: [DATE] · Review annually._'),
  ('retention_schedule','Data Retention & Disposal Schedule', E'# Data Retention & Disposal Schedule\n\nPer POPIA s.14, personal information is kept only as long as necessary.\n\n| Data category | Retention period | Legal basis | Disposal method |\n|---|---|---|---|\n| [Employee records] | [5 years after exit] | [BCEA / SARS] | [Secure deletion] |\n| [Customer records] | [period] | [basis] | [method] |\n\n[Add rows per PI category from the ROPA.]\n\n_Owner: Information Officer · Review annually._'),
  ('dsr_procedure','Data Subject Request Procedure', E'# Data Subject Request (DSR) Procedure\n\nData subjects may request access, correction, deletion or objection under POPIA. We respond within 30 days.\n\n## Steps\n1. **Receive** — log the request (date, requester, type).\n2. **Verify identity** — per the identity-verification SOP.\n3. **Action** — locate, compile, action within 30 days.\n4. **Respond** — in writing; record the outcome.\n\n## Escalation\n[Complaints escalate to the Information Officer, then the Information Regulator.]\n\n_Owner: Information Officer._'),
  ('breach_procedure','Data Breach Response Procedure', E'# Data Breach Response Procedure\n\nPer POPIA s.22, security compromises are notified to the Information Regulator and affected data subjects.\n\n## On detection\n1. **Contain** — isolate the affected system/data.\n2. **Assess** — scope, data subjects, risk of harm.\n3. **Notify** — the Information Regulator as soon as reasonably possible; affected data subjects where there is a risk of harm.\n4. **Record** — in the Breach Register.\n5. **Review** — post-incident lessons learned.\n\n_Owner: Information Officer · Notification templates attached._'),
  ('internal_privacy_policy','Internal Privacy Policy', E'# Internal Privacy Policy\n\nThis policy sets out staff obligations when handling personal information under POPIA.\n\n## 1. Data minimisation\nCollect and access only what is needed for the task.\n\n## 2. Handling\n[Storage, sharing, clean-desk, device security.]\n\n## 3. Breach reporting\nReport suspected breaches to the Information Officer immediately.\n\n## 4. Consequences\nNon-compliance may result in disciplinary action.\n\n_All staff must acknowledge this policy._')
) AS x(slot_key,name,body);

COMMIT;
