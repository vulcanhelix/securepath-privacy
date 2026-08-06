-- Table privileges for API roles. RLS (forced) remains the actual isolation gate;
-- these grants only let policies come into play. anon gets nothing in public.

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.practices, public.client_orgs,
  public.users, public.memberships, public.consultant_assignments,
  public.assessments TO authenticated;
GRANT SELECT, INSERT ON public.audit_log TO authenticated;  -- append-only
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
