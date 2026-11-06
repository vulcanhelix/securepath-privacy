-- 20261106000000_designation_probe_fix.sql — orchestrator fix (schema-request class)
-- Two probe bugs on the alternate-officer path:
--   1. kinds probed ('Deputy Information Officer','dio','alternate') aren't in
--      designations.role CHECK — only named_alternate/deputy_information_officer/dpo exist.
--   2. holds_designation ignored end_date: an EXPIRED alternate still passed.
CREATE OR REPLACE FUNCTION public.holds_designation(p_client_org uuid, p_kinds text[])
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_person_col text; v_kind_col text; v_result boolean;
BEGIN
  IF to_regclass('public.designations') IS NULL THEN RETURN false; END IF;
  SELECT column_name INTO v_person_col FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'designations'
     AND column_name IN ('person','user_id','person_id','designee')
   ORDER BY CASE column_name WHEN 'person' THEN 0 WHEN 'user_id' THEN 1
                             WHEN 'person_id' THEN 2 ELSE 3 END
   LIMIT 1;
  SELECT column_name INTO v_kind_col FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'designations'
     AND column_name IN ('role','designation','designation_kind','kind')
   ORDER BY CASE column_name WHEN 'role' THEN 0 WHEN 'designation' THEN 1
                             WHEN 'designation_kind' THEN 2 ELSE 3 END
   LIMIT 1;
  IF v_person_col IS NULL OR v_kind_col IS NULL THEN RETURN false; END IF;
  EXECUTE format(
    'SELECT EXISTS (SELECT 1 FROM public.designations d
                     WHERE d.client_org_id = $1 AND d.%I = $2 AND d.%I = ANY($3)
                       AND (d.end_date IS NULL OR d.end_date >= CURRENT_DATE))',
    v_person_col, v_kind_col)
    INTO v_result USING p_client_org, auth.uid(), p_kinds;
  RETURN COALESCE(v_result, false);
END $$;
CREATE OR REPLACE FUNCTION public.is_ao_or_alternate(p_client_org uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.role_assignments ra
    WHERE ra.user_id = auth.uid() AND ra.level = 'client'
      AND ra.role = 'accountable_officer'
      AND ra.start_date <= CURRENT_DATE
      AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
      AND ( (ra.scope_type = 'client' AND ra.scope_id = p_client_org)
         OR (ra.scope_type = 'programme' AND ra.scope_id IN
              (SELECT p.id FROM public.programmes p WHERE p.client_org_id = p_client_org)) ))
  OR public.holds_designation(p_client_org,
       ARRAY['named_alternate','deputy_information_officer','dpo'])
$$;
COMMENT ON FUNCTION public.is_ao_or_alternate(uuid) IS
  'T5: AO or alternate on this client. Alternate = LIVE named_alternate / '
  'deputy_information_officer / dpo designation (end_date now honoured).';
