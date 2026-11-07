-- 20261106000018_scoped_programme_context.sql — W4-D fixes (found by the
-- W4-00 Playwright harness, PR #97). Two scoped-role access defects:
--
-- W4-D3 — a workstream-scope-only caller (workstream_lead — the spec B.13
--   screen-08 user) cannot see their programme at all: allowed_programmes()
--   deliberately excluded workstream scope ("a workstream lead sees their
--   own workstream via T3, not the whole programme"). But every workstream
--   screen is shelled under /programmes/[id], so the exclusion 404s the
--   workstream lead everywhere. Add the workstream→programme branch below.
--   Read-only widening: write gates (has_workstream_role/has_activity_role)
--   already scope writes to the caller's own workstream/items.
--
-- W4-D2 — a programme-scope-only caller (programme_lead whose only
--   role_assignments row is scope_type='programme'; now also the W4-D3
--   workstream lead) reads the programmes row (programmes_read: id IN
--   allowed_programmes()) but NOT the owning client_orgs row —
--   allowed_client_orgs() has no programme-scope branch, and must not gain
--   one: a scoped programme role must not widen into the whole client's
--   data. The app's programmeContext() resolves programme → client and
--   therefore 404s for these callers on every /programmes/[id]/* screen.
--   Fix follows the partner_branding precedent (20261106000010): a small
--   SECURITY DEFINER programme_context(p_programme) RPC returning exactly
--   the programme + client slices the app shell needs, guarded in-body by
--   allowed_programmes() — no RLS widening.

-- ---------- allowed_programmes() v2 — + workstream-scope branch ----------
CREATE OR REPLACE FUNCTION public.allowed_programmes() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id FROM public.programmes p
   WHERE p.client_org_id IN (SELECT public.allowed_client_orgs())
  UNION
  SELECT ra.scope_id
    FROM public.role_assignments ra
   WHERE ra.user_id = auth.uid()
     AND ra.scope_type = 'programme'
     AND ra.level IN ('partner','client')
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
  UNION
  -- W4-D3: a workstream-scope assignment grants the programme carrying that
  -- workstream (spec B.13 — the workstream lead is the screen-08 user).
  SELECT w.programme_id
    FROM public.role_assignments ra
    JOIN public.workstreams w ON w.id = ra.scope_id
   WHERE ra.user_id = auth.uid()
     AND ra.scope_type = 'workstream'
     AND ra.level IN ('partner','client')
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
$$;
COMMENT ON FUNCTION public.allowed_programmes() IS
  'W0-02 + W4-D3: programme ids the caller may see — programmes of all '
  'visible clients, direct programme-scope assignments, and programmes '
  'carrying the caller''s workstream-scope assignments. T2 read.';

-- ---------- programme_context() — the app shell's programme+client slice --
CREATE OR REPLACE FUNCTION public.programme_context(p_programme uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row jsonb;
BEGIN
  -- A definer function bypasses RLS, so the scope guard lives in the body
  -- (the established hard rule). auth.uid() NULL = the service/migration
  -- path and runs free (W0-02 convention).
  IF auth.uid() IS NOT NULL
     AND p_programme NOT IN (SELECT public.allowed_programmes()) THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object(
      'programme', jsonb_build_object(
        'id',             p.id,
        'name',           p.name,
        'status',         p.status,
        'phase',          p.phase,
        'start_date',     p.start_date,
        'total_weeks',    p.total_weeks,
        'programme_rag',  p.programme_rag,
        'programme_lead', p.programme_lead,
        'client_org_id',  p.client_org_id),
      'client', jsonb_build_object(
        'id',           c.id,
        'name',         c.name,
        'practice_id',  c.practice_id,
        'jurisdiction', c.jurisdiction,
        'legal_name',   c.legal_name,
        'trading_name', c.trading_name)
    ) INTO v_row
    FROM public.programmes p
    JOIN public.client_orgs c ON c.id = p.client_org_id
   WHERE p.id = p_programme;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.programme_context(uuid) IS
  'W4-D2: programme + owning-client slice for the app shell. DEFINER because '
  'programme/workstream-scope callers see the programme but not client_orgs; '
  'guarded by allowed_programmes() so nothing extra leaks.';
REVOKE EXECUTE ON FUNCTION public.programme_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.programme_context(uuid) TO authenticated;
