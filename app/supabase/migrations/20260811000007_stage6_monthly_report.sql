-- STAGE 6 — Managed service: the monthly cycle. The steady state, on the spine.
-- A monthly report shows movement against the Stage 1 baseline (the score anchors the whole
-- relationship). Compile pulls the period's structured data; approve-and-issue writes an
-- immutable archived document. No gate — the loop back to Stage 1 is the annual reassessment.

BEGIN;

CREATE TABLE public.monthly_reports (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_org_id   uuid NOT NULL REFERENCES public.client_orgs(id) ON DELETE CASCADE,
    track_id        uuid REFERENCES public.tracks(id),
    period          text NOT NULL,              -- 'YYYY-MM'
    title           text NOT NULL,
    body            text NOT NULL DEFAULT '',
    baseline_pct    int,                        -- Stage 1 approved assessment score (month zero)
    baseline_rating text,
    tasks_done      int,
    tasks_total     int,
    approval_status public.approval_status NOT NULL DEFAULT 'draft_human',
    version         int NOT NULL DEFAULT 1,
    created_by      uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_monthly_reports_client ON public.monthly_reports (client_org_id, period DESC);

ALTER TABLE public.monthly_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_reports FORCE ROW LEVEL SECURITY;
CREATE POLICY monthly_reports_read ON public.monthly_reports FOR SELECT TO authenticated
  USING (client_org_id IN (SELECT public.allowed_client_orgs()));
REVOKE ALL ON public.monthly_reports FROM anon;
GRANT SELECT ON public.monthly_reports TO authenticated;

-- draft a report for a period (compile builds the body app-side). One working draft per period.
CREATE FUNCTION public.record_monthly_report(
    p_client_org_id uuid, p_period text, p_title text, p_body text,
    p_baseline_pct int, p_baseline_rating text, p_tasks_done int, p_tasks_total int)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid; v_track uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to client organisation'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant') THEN
    RAISE EXCEPTION 'only advisors may compile the monthly report';
  END IF;
  SELECT id INTO v_track FROM tracks WHERE client_org_id = p_client_org_id AND track_kind = 'privacy';
  DELETE FROM monthly_reports WHERE client_org_id = p_client_org_id AND period = p_period
    AND approval_status IN ('draft_ai','draft_human');
  INSERT INTO monthly_reports (client_org_id, track_id, period, title, body, baseline_pct, baseline_rating, tasks_done, tasks_total, created_by)
    VALUES (p_client_org_id, v_track, p_period, p_title, p_body, p_baseline_pct, p_baseline_rating, p_tasks_done, p_tasks_total, auth.uid())
    RETURNING id INTO rid;
  INSERT INTO audit_log (user_id, practice_id, action, detail)
    VALUES (auth.uid(), current_practice(), 'monthly_report.compiled', jsonb_build_object('report_id', rid, 'period', p_period));
  RETURN rid;
END $$;

-- approve-and-issue: render to an immutable archived document, mark issued, log. No stage change
-- (steady state). Called server-side after the body is written to storage.
CREATE FUNCTION public.issue_monthly_report(p_report_id uuid, p_storage_path text, p_sha256 text, p_size bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v monthly_reports%ROWTYPE; did uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v FROM monthly_reports WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'report not found'; END IF;
  IF v.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN RAISE EXCEPTION 'Access denied to report'; END IF;
  IF public.current_role_name() NOT IN ('practice_owner','practice_consultant','client_admin') THEN
    RAISE EXCEPTION 'only advisors or the client admin may issue the report';
  END IF;
  IF v.approval_status NOT IN ('draft_ai','draft_human') THEN RAISE EXCEPTION 'report already issued'; END IF;

  INSERT INTO documents (client_org_id, track_id, original_filename, mime, size, sha256, storage_path, uploaded_by)
    VALUES (v.client_org_id, v.track_id, v.title || '.md', 'text/markdown', p_size, p_sha256, p_storage_path, auth.uid())
    RETURNING id INTO did;
  UPDATE monthly_reports SET approval_status = 'issued', updated_at = now() WHERE id = p_report_id;
  PERFORM public.record_approval('monthly_report', p_report_id, 'issued', 'Monthly report issued: ' || v.period);
  RETURN did;
END $$;

REVOKE EXECUTE ON FUNCTION
  public.record_monthly_report(uuid, text, text, text, int, text, int, int),
  public.issue_monthly_report(uuid, text, text, bigint)
FROM anon, public;
GRANT EXECUTE ON FUNCTION
  public.record_monthly_report(uuid, text, text, text, int, text, int, int),
  public.issue_monthly_report(uuid, text, text, bigint)
TO authenticated;

COMMIT;
