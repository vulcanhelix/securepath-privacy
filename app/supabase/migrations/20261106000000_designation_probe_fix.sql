-- 20261106000000_designation_probe_fix.sql — orchestrator fix (schema-request class)
-- is_ao_or_alternate() probed designation kinds that can never exist:
--   'Deputy Information Officer' / 'dio' / 'alternate'
-- but designations.role CHECK (000002) allows only
--   information_officer | deputy_information_officer | dpo | named_alternate
-- so only 'named_alternate' could ever match (W0-05 fixture agent flagged it).
-- A deputy_information_officer / dpo IS the alternate officer under POPIA —
-- fold them into the alternate leg alongside named_alternate.

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
  'T5: caller is AO or alternate on this client. Alternate = named_alternate, '
  'deputy_information_officer or dpo designation (values matching the CHECK).';
