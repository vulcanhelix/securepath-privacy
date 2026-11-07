-- ============================================================================
-- W4-06 field-level audit_events — NFR-08 "append-only audit trail of every
-- change at every level"; spec data model "Audit event: Entity, record, field,
-- old and new value, user, organisation, timestamp — every change, every
-- level"; report catalogue "Audit trail extract — on demand, admins only";
-- AT-21 "admin tries to edit or delete an audit event — not possible".
--
-- audit_log (W0) is the append-only ACTION ledger written by RPCs. This adds
-- FIELD-level capture: a generic trigger records table/row/column/old/new/
-- actor/timestamp for every INSERT, UPDATE, DELETE and TRUNCATE on every
-- tenant-scoped table, whether the write came through a definer RPC, a direct
-- RLS-checked write, or the service path.
--
-- Table inventory (every public table is either ATTACHED or EXCLUDED; the
-- drift guard app/tests/check_audit_trigger_coverage.py fails CI if a future
-- migration adds a table that is neither):
--
--   EXCLUDED — audit ledgers themselves (self-reference):
--     audit_log, audit_events
--   EXCLUDED — notification fan-out / delivery bookkeeping (churn; the
--   originating events already land in audit_log / billing_events):
--     notifications, notification_events, notification_recipients
--   EXCLUDED — platform scheduler bookkeeping (high churn, not tenant data):
--     scheduled_jobs, job_runs
--   EXCLUDED — bulk-import staging rows (high volume, transient; the parent
--   import_runs row IS audited):
--     import_rows
--   EXCLUDED — NFR-15: awareness answers may be stored/reported only as
--   averages; per-respondent old/new capture would retain a second
--   identifiable copy of individual responses:
--     awareness_respondents, awareness_responses
--   EXCLUDED — platform/global content packs + registries (not tenant
--   records; partner-authored packs/templates below ARE attached):
--     frameworks, jurisdiction_packs, assessment_questions,
--     awareness_questions, document_checklists, manual_outlines,
--     policy_templates, task_templates, requirement_mappings
--   EXCLUDED — retired/derived objects, not real tables any more:
--     memberships   (dropped by W0-00; now a compat VIEW over role_assignments)
--     assessments   (legacy stub, dropped by 20260807000004 when empty)
--
--   ATTACHED — everything else: tenancy (practices, client_orgs, users,
--   consultant_assignments, role_assignments, notification_preferences,
--   invites), billing/approval/stage ledgers (billing_events, approvals,
--   stage_transitions — already append-only, but the trigger is what catches
--   a DELETE against them), the stage 0-6 pipeline tables, the programme
--   engine tables incl. programme_id-keyed children, platform-issued but
--   partner-owned records (licences, programme_templates(+versions),
--   import_runs, content_packs, support_access_*).
--
-- HOT-PATH VOLUME NOTE: INSERT/DELETE emit ONE event row each (whole record
-- in old/new_value); UPDATE emits one row per CHANGED column — that is the
-- field-level capture the spec asks for and where the volume lives. The
-- highest-churn tables are excluded above; remaining hot paths (task status
-- updates, kpi_actuals, assessment_responses) produce single-digit event rows
-- per write. Retention/partitioning is deliberately not built — audit_events
-- is append-only and can be archived/partitioned later without schema change.
--
-- Actor resolution: auth.uid() when a user JWT drove the write (definer RPCs
-- keep the caller's claims, so the real user is captured even through
-- SECURITY DEFINER paths); JWT role 'service_role' or a claims-less psql /
-- migration write records actor 'service'; any other role label is recorded
-- verbatim.
-- ============================================================================

-- ---------- the table ----------
CREATE TABLE public.audit_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at            timestamptz NOT NULL DEFAULT now(),
    action        text NOT NULL CHECK (action IN ('insert','update','delete','truncate')),
    table_name    text NOT NULL,                  -- spec "Entity"
    row_id        text NOT NULL,                  -- spec "record": pk cols as 'k=v,k=v'
    column_name   text NOT NULL,                  -- spec "field"; '(row)' = whole-record event
    old_value     jsonb,                          -- NULL on insert
    new_value     jsonb,                          -- NULL on delete
    actor         text NOT NULL,                  -- spec "user": uid text or 'service'/role label
    actor_id      uuid,                           -- auth.uid() when a user JWT drove the write
    practice_id   uuid,                           -- spec "organisation" (partner tenant)
    client_org_id uuid                            -- spec "organisation" (client tenant)
);
COMMENT ON TABLE public.audit_events IS
  'W4-06 NFR-08 field-level audit: one row per changed column on UPDATE, one '
  'per record on INSERT/DELETE, one per TRUNCATE statement. Append-only — no '
  'UPDATE/DELETE/SELECT grants and no RLS policies; reads go through '
  'platform_audit_extract() only. actor = auth.uid() text, or ''service'' for '
  'claims-less / service_role writes.';

CREATE INDEX audit_events_client_idx  ON public.audit_events (client_org_id, at);
CREATE INDEX audit_events_practice_idx ON public.audit_events (practice_id, at);
CREATE INDEX audit_events_table_row_idx ON public.audit_events (table_name, row_id, at);

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events FORCE ROW LEVEL SECURITY;
-- No policies at all: invisible to every non-superuser role, including
-- platform admins (AT-21). The definer trigger function inserts as owner;
-- the definer extract RPC reads as owner.
REVOKE ALL ON public.audit_events FROM authenticated, anon, service_role;

-- ---------- actor helper ----------
-- 'service' when no user JWT is driving (service_role claim, or a claims-less
-- psql/migration/test-harness write); the JWT role label otherwise; the uid
-- itself when a user is authenticated — audit_events.actor keeps the text.
CREATE FUNCTION public.audit_actor_label(p_actor_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_role text;
BEGIN
  IF p_actor_id IS NOT NULL THEN RETURN p_actor_id::text; END IF;
  BEGIN
    v_role := coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '');
  EXCEPTION WHEN OTHERS THEN
    v_role := '';
  END;
  RETURN CASE WHEN v_role IN ('', 'service_role') THEN 'service' ELSE v_role END;
END $$;

-- ---------- row trigger ----------
-- TG_ARGV[0] = pk column names (jsonb array, baked at attach time)
-- TG_ARGV[1] = tenant path (jsonb array of {"col","table","target"} hops —
--   follow row.<col> -> <table>.<target= id> until a row carrying
--   client_org_id / practice_id / partner_id is reached)
-- TG_ARGV[2] = tenant mode: 'chain' (default; path above, [] = read tenant
--   cols off the row itself), 'self_practice' (row IS practices),
--   'self_client' (row IS client_orgs), 'user:<col>' (resolve via the user's
--   role_assignments), 'ra' (role_assignments' own polymorphic scope)
CREATE FUNCTION public.audit_capture() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old      jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  v_new      jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END;
  v_pk_cols  jsonb := TG_ARGV[0]::jsonb;
  v_path     jsonb := coalesce(TG_ARGV[1]::jsonb, '[]'::jsonb);
  v_mode     text  := coalesce(TG_ARGV[2], 'chain');
  v_row      jsonb := coalesce(v_new, v_old);
  v_tenant   jsonb := v_row;
  v_hop      jsonb;
  v_fk       text;
  v_last_table text;
  v_row_id   text;
  v_actor_id uuid;
  v_actor    text;
  v_practice uuid;
  v_client   uuid;
  k          text;
BEGIN
  -- ---------- actor (never breaks the write) ----------
  BEGIN
    v_actor_id := auth.uid();
    v_actor    := public.audit_actor_label(v_actor_id);
  EXCEPTION WHEN OTHERS THEN
    v_actor_id := NULL; v_actor := 'service';
  END;

  -- ---------- row id ----------
  SELECT string_agg(format('%s=%s', p.key, coalesce(v_row ->> p.key, '∅')), ',')
    INTO v_row_id
    FROM jsonb_array_elements_text(v_pk_cols) AS p(key);
  v_row_id := coalesce(v_row_id, '*');

  -- ---------- tenant resolution (best-effort; an audit miss must never
  -- abort the write it is auditing) ----------
  BEGIN
    IF v_mode = 'self_practice' THEN
      v_practice := (v_row ->> 'id')::uuid;
    ELSIF v_mode = 'self_client' THEN
      v_client   := (v_row ->> 'id')::uuid;
      v_practice := (v_row ->> 'practice_id')::uuid;
    ELSIF v_mode = 'ra' THEN
      -- role_assignments: scope is polymorphic on scope_type/scope_id
      IF v_row ->> 'scope_type' = 'partner' THEN
        v_practice := (v_row ->> 'scope_id')::uuid;
      ELSIF v_row ->> 'scope_type' = 'client' THEN
        v_client := (v_row ->> 'scope_id')::uuid;
        SELECT practice_id INTO v_practice
          FROM public.client_orgs WHERE id = v_client;
      ELSIF v_row ->> 'scope_type' = 'programme' THEN
        SELECT p.client_org_id, co.practice_id INTO v_client, v_practice
          FROM public.programmes p
          JOIN public.client_orgs co ON co.id = p.client_org_id
         WHERE p.id = (v_row ->> 'scope_id')::uuid;
      ELSIF v_row ->> 'scope_type' = 'workstream' THEN
        SELECT p.client_org_id, co.practice_id INTO v_client, v_practice
          FROM public.workstreams w
          JOIN public.programmes p ON p.id = w.programme_id
          JOIN public.client_orgs co ON co.id = p.client_org_id
         WHERE w.id = (v_row ->> 'scope_id')::uuid;
      END IF;
    ELSIF v_mode LIKE 'user:%' THEN
      -- user-adjacent rows (users, notification_preferences): tag the tenant
      -- of the user's primary assignment — partner scope preferred.
      SELECT CASE WHEN ra.scope_type = 'partner' THEN ra.scope_id
                  ELSE co.practice_id END,
             CASE WHEN ra.scope_type = 'client'  THEN ra.scope_id END
        INTO v_practice, v_client
        FROM public.role_assignments ra
        LEFT JOIN public.client_orgs co
               ON ra.scope_type = 'client' AND co.id = ra.scope_id
       WHERE ra.user_id = (v_row ->> split_part(v_mode, ':', 2))::uuid
         AND ra.scope_type IN ('partner','client')
       ORDER BY CASE WHEN ra.scope_type = 'partner' THEN 0 ELSE 1 END
       LIMIT 1;
    ELSE
      -- 'chain': follow fk hops to a row carrying tenant columns. Chains are
      -- built to END at client_orgs / practices, so a terminal row whose own
      -- id IS the tenant key is handled too.
      FOR i IN 0 .. greatest(jsonb_array_length(v_path) - 1, -1) LOOP
        v_hop := v_path -> i;
        v_fk  := v_tenant ->> (v_hop ->> 'col');
        EXIT WHEN v_fk IS NULL;
        v_last_table := v_hop ->> 'table';
        EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I = $1',
                       v_hop ->> 'table', coalesce(v_hop ->> 'target', 'id'))
          INTO v_tenant USING v_fk::uuid;
        EXIT WHEN v_tenant IS NULL;
      END LOOP;
      IF (v_tenant ->> 'client_org_id') IS NOT NULL THEN
        v_client := (v_tenant ->> 'client_org_id')::uuid;
      ELSIF v_last_table = 'client_orgs' AND (v_tenant ->> 'id') IS NOT NULL THEN
        v_client := (v_tenant ->> 'id')::uuid;
      END IF;
      IF (v_tenant ->> 'practice_id') IS NOT NULL THEN
        v_practice := (v_tenant ->> 'practice_id')::uuid;
      ELSIF (v_tenant ->> 'partner_id') IS NOT NULL THEN
        v_practice := (v_tenant ->> 'partner_id')::uuid;
      ELSIF v_last_table = 'practices' AND (v_tenant ->> 'id') IS NOT NULL THEN
        v_practice := (v_tenant ->> 'id')::uuid;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_client := NULL; v_practice := NULL;
  END;

  -- ---------- emit ----------
  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(v_new) LOOP
      IF (v_old -> k) IS DISTINCT FROM (v_new -> k) THEN
        INSERT INTO public.audit_events
          (action, table_name, row_id, column_name, old_value, new_value,
           actor, actor_id, practice_id, client_org_id)
        VALUES ('update', TG_TABLE_NAME, v_row_id, k,
                v_old -> k, v_new -> k,
                v_actor, v_actor_id, v_practice, v_client);
      END IF;
    END LOOP;
  ELSE
    INSERT INTO public.audit_events
      (action, table_name, row_id, column_name, old_value, new_value,
       actor, actor_id, practice_id, client_org_id)
    VALUES (lower(TG_OP), TG_TABLE_NAME, v_row_id, '(row)',
            v_old, v_new, v_actor, v_actor_id, v_practice, v_client);
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;

-- ---------- truncate guard ----------
-- Row triggers never fire on TRUNCATE; without this a bulk wipe is the one
-- change invisible to field-level audit. Statement-level: one event row.
CREATE FUNCTION public.audit_capture_truncate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.audit_events
    (action, table_name, row_id, column_name, actor, actor_id)
  VALUES ('truncate', TG_TABLE_NAME, '*', '(row)',
          public.audit_actor_label(auth.uid()), auth.uid());
  RETURN NULL;
END $$;

-- ---------- attach helper (used by this migration and REQUIRED for every
-- future tenant table; the coverage checker greps these calls) ----------
CREATE FUNCTION public.attach_audit_trigger(
    p_table text,
    p_path  jsonb DEFAULT '[]'::jsonb,
    p_mode  text  DEFAULT 'chain')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pk jsonb;
BEGIN
  SELECT jsonb_agg(a.attname ORDER BY k.ord) INTO v_pk
  FROM pg_constraint con
  JOIN pg_class c      ON c.oid = con.conrelid
  JOIN pg_namespace n  ON n.oid = c.relnamespace
  CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a  ON a.attrelid = c.oid AND a.attnum = k.attnum
  WHERE con.contype = 'p' AND n.nspname = 'public' AND c.relname = p_table;
  IF v_pk IS NULL THEN
    RAISE EXCEPTION 'attach_audit_trigger: public.% has no primary key', p_table;
  END IF;
  EXECUTE format(
    'CREATE TRIGGER audit_events_trg AFTER INSERT OR UPDATE OR DELETE ON public.%I
       FOR EACH ROW EXECUTE FUNCTION public.audit_capture(%L, %L, %L)',
    p_table, v_pk::text, coalesce(p_path, '[]'::jsonb)::text, coalesce(p_mode, 'chain'));
  EXECUTE format(
    'CREATE TRIGGER audit_events_trunc_trg AFTER TRUNCATE ON public.%I
       FOR EACH STATEMENT EXECUTE FUNCTION public.audit_capture_truncate()', p_table);
END $$;
COMMENT ON FUNCTION public.attach_audit_trigger(text, jsonb, text) IS
  'W4-06: attach field-level audit triggers to a tenant table. MANDATORY for '
  'every new tenant-scoped table — app/tests/check_audit_trigger_coverage.py '
  'fails CI on any public table that is neither attached nor a documented '
  'exclusion. p_path = fk-hop chain to the tenant key, p_mode selects the '
  'tenant-resolution strategy (see audit_capture).';

-- ============================================================================
-- THE INVENTORY — every tenant-scoped table, one line each.
-- Every chain ENDS at client_orgs or practices so both tenant columns resolve.
-- (exclusions are listed in the header comment + the coverage checker)
-- ============================================================================

-- ---- tenancy core + users-adjacent ----
SELECT public.attach_audit_trigger('practices',              '[]', 'self_practice');
SELECT public.attach_audit_trigger('client_orgs',            '[]', 'self_client');
SELECT public.attach_audit_trigger('users',                  '[]', 'user:id');
SELECT public.attach_audit_trigger('consultant_assignments',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('role_assignments',       '[]', 'ra');
SELECT public.attach_audit_trigger('notification_preferences','[]', 'user:user_id');
SELECT public.attach_audit_trigger('invites',                '[]', 'chain');

-- ---- append-only ledgers (the trigger is what catches a delete) ----
SELECT public.attach_audit_trigger('billing_events',         '[]', 'chain');
SELECT public.attach_audit_trigger('approvals',              '[]', 'chain');
SELECT public.attach_audit_trigger('stage_transitions',
  '[{"col":"track_id","table":"tracks"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');

-- ---- stage 0-6 pipeline (client_org_id-keyed) ----
SELECT public.attach_audit_trigger('assessment_sessions',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('assessment_responses',
  '[{"col":"session_id","table":"assessment_sessions"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('assessment_scores',
  '[{"col":"session_id","table":"assessment_sessions"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('assessment_reports',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('tracks',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('documents',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('document_links',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('policies',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('manuals',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('tasks',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('monthly_reports',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('awareness_cohorts',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');

-- ---- platform-tier tenant records ----
SELECT public.attach_audit_trigger('designations',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('support_access_grants',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('support_access_requests',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('licences',               '[]', 'chain'); -- partner_id
SELECT public.attach_audit_trigger('content_packs',          '[]', 'chain'); -- practice_id NULL=global
SELECT public.attach_audit_trigger('programme_templates',    '[]', 'chain'); -- partner_id
SELECT public.attach_audit_trigger('programme_template_versions',
  '[{"col":"template_id","table":"programme_templates"}]', 'chain');
SELECT public.attach_audit_trigger('import_runs',            '[]', 'chain'); -- partner_id

-- ---- programme engine: programme_id-keyed children (2 hops) ----
SELECT public.attach_audit_trigger('programmes',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('phases',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('workstreams',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('activities',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('register_items',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('evidence_items',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('evidence_offers',
  '[{"col":"evidence_item_id","table":"evidence_items"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('weekly_logs',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('kpis',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('raid_items',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('maintenance_task_templates',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('checklist_instances',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('checklist_item_completions',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('monthly_snapshots',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('programme_reports',
  '[{"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('operational_records',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('training_records',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('controlled_documents',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('external_providers',
  '[{"col":"client_org_id","table":"client_orgs"}]', 'chain');

-- ---- programme engine: grandchildren (3 hops) ----
SELECT public.attach_audit_trigger('activity_deps',
  '[{"col":"activity_id","table":"activities"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('activity_status_history',
  '[{"col":"activity_id","table":"activities"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('register_item_activities',
  '[{"col":"register_item_id","table":"register_items"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('controlled_document_activities',
  '[{"col":"controlled_document_id","table":"controlled_documents"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('evidence_reviews',
  '[{"col":"evidence_item_id","table":"evidence_items"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('kpi_actuals',
  '[{"col":"kpi_id","table":"kpis"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('raid_status_history',
  '[{"col":"raid_item_id","table":"raid_items"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('decisions',
  '[{"col":"raid_item_id","table":"raid_items"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');
SELECT public.attach_audit_trigger('maintenance_task_instances',
  '[{"col":"task_template_id","table":"maintenance_task_templates"},
    {"col":"programme_id","table":"programmes"},
    {"col":"client_org_id","table":"client_orgs"}]', 'chain');

-- ---------- admin extract ----------
-- Spec report catalogue: "Audit trail extract — client/partner/platform,
-- on demand, admins only". platform_admin only, guarded in-body (definer RPC
-- bypasses RLS, so the check must live here — repo convention).
CREATE FUNCTION public.platform_audit_extract(
    p_client_org_id uuid        DEFAULT NULL,
    p_practice_id   uuid        DEFAULT NULL,
    p_table_name    text        DEFAULT NULL,
    p_from          timestamptz DEFAULT NULL,
    p_to            timestamptz DEFAULT NULL,
    p_limit         int         DEFAULT 1000)
RETURNS SETOF public.audit_events
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin']) THEN
    RAISE EXCEPTION 'platform_audit_extract: platform_admin required';
  END IF;
  RETURN QUERY
    SELECT e.* FROM public.audit_events e
    WHERE (p_client_org_id IS NULL OR e.client_org_id = p_client_org_id)
      AND (p_practice_id   IS NULL OR e.practice_id   = p_practice_id)
      AND (p_table_name    IS NULL OR e.table_name    = p_table_name)
      AND (p_from          IS NULL OR e.at >= p_from)
      AND (p_to            IS NULL OR e.at <  p_to)
    ORDER BY e.at, e.id
    LIMIT least(greatest(p_limit, 1), 10000);
END $$;
COMMENT ON FUNCTION public.platform_audit_extract IS
  'W4-06 NFR-08 admin extract: audit_events for a tenant/table/period. '
  'platform_admin only (support gets nothing — §4.1 least privilege). The '
  'only read path into audit_events besides direct psql.';

-- ---------- grant surface ----------
REVOKE EXECUTE ON FUNCTION public.audit_actor_label(uuid),
  public.audit_capture(), public.audit_capture_truncate(),
  public.attach_audit_trigger(text, jsonb, text)
  FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.platform_audit_extract(uuid, uuid, text,
  timestamptz, timestamptz, int) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.platform_audit_extract(uuid, uuid, text,
  timestamptz, timestamptz, int) TO authenticated;
