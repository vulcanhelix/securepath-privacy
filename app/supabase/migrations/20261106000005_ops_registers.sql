-- ============================================================================
-- W1-04 — OPERATIONAL REGISTERS RPCs: DSR / breach / disclosure / opt-out
-- registers, the breach route (report → AO decision → close), and the
-- external-provider contact book.
-- (GitHub #18 · spec SP-SPC-PLT-001 §6.2/§8.10 FR-OPS-01..05, §9.7, §10,
--  FR-ACC-02 · plan BUILD_PLAN_R1 W1-04 · deps: W0-02 programme engine,
--  W1-01 rules engine)
-- ============================================================================
--
-- Built ON the existing spine — nothing reimplemented:
--   * operational_records / external_providers tables, RLS and column grants
--     are W0-02's (00003). due_date / closed_on / regulator_notification are
--     WRITE-PROTECTED columns: no authenticated grant + oprecord_regulator_gate
--     (AO-or-alternate trigger). This file changes neither — the gated
--     definers below are the ONLY writers of those fields.
--   * due_date arithmetic is W1-01's: deadline_rule + deadline_params on the
--     row → trg_oprecord_due_date resolves it through jurisdiction_packs.
--     deadline_params (§9.7) on INSERT/UPDATE. No legal period is hard-coded
--     anywhere in this file (FR-OPS-02).
--   * Breach alerting rides the §10 notification_events outbox exactly like
--     W1-06's decision_recorded event — 'breach_alert' is emitted in the same
--     transaction as the record insert, so dispatch (W1-08) can send it at
--     once and never via the daily digest (spec §10: breach alerts always
--     immediate).
--
-- SECURITY MODEL (hard rule): every SECURITY DEFINER guards in its body.
--   * record_breach / create_operational_record(type='breach'): any caller
--     who can SEE the client may report — FR-OPS-04 deliberately matches the
--     W0-02 insert policy (any screen, any user).
--   * other register writes + provider writes: has_client_role() with the
--     same role set as the W0-02 write policies.
--   * record_breach_decision: is_ao_or_alternate() — FR-ACC-02. The JWT-path
--     trigger then re-checks the same gate inside the update (belt+braces;
--     the definer IS the only path that can write the column anyway).
--   * list_*: scope-checked reads returning RLS-shaped results.
--
-- DEVIATIONS / DECISIONS (spec ambiguities resolved — flagged for review):
--   1. Register-type vocabulary = the shipped CHECK ('dsr','breach',
--      'disclosure','optout') — the mission packet's longer list maps onto it:
--      'incident' folds into 'breach' (§6.2 "breach or incident" is ONE type),
--      'training' is the separate training_records table, and 'processing' /
--      'vendor' registers are not in the v0.2 operational-register spec
--      (external_providers already covers the named-supplier contact book).
--      create_operational_record rejects anything outside the CHECK.
--   2. Default deadline_rule per type follows the W0-05 fixture "registers"
--      contract: dsr→'data_subject_request', breach→'breach_notification',
--      optout→'opt_out', disclosure→NULL (no statutory clock). A payload may
--      override the rule name (framework-specific targets, §9.7).
--   3. record_breach creates the record at 'Awaiting decision' — the breach
--      route's next step after report+log IS the AO assessment (FR-OPS-03);
--      the fixture's mobile-reported breach sits in the same state.
--   4. record_breach_decision keeps an append-only 'history' inside the
--      regulator_notification jsonb plus the latest decision at top level
--      (the KPI calc 'count(breach where regulator_notified)' reads
--      .decision). Recording a decision moves 'Awaiting decision' →
--      'In progress' (assessment done, notification executing); other
--      statuses are untouched. A Closed record rejects new decisions.
--   5. close_operational_record requires a closure note for type='breach'
--      ("close with lessons learned", FR-OPS-03); for other types the note
--      is optional and, when given, is appended to outcome (the schema has
--      no closure-note column).
--   6. "any user" for breach reporting is implemented as client visibility
--      (allowed_client_orgs()), mirroring the W0-02 insert policy — the
--      narrowest reading that still lets a client staff member report from
--      a phone (AT-19).
--   7. list_operational_records pages via filters jsonb {status, overdue,
--      due_before, due_after, reported_after, reported_before, limit,
--      offset}; limit clamps at 200, default 50.
-- ============================================================================

BEGIN;

-- ---------- 0. write-role sets (match the W0-02 table policies) ----------
-- register writes : partner_admin, partner_consultant, programme_lead,
--                   client_admin, accountable_officer   (oprecords update policy)
-- provider writes : partner_admin, partner_consultant, programme_lead,
--                   client_admin                        (providers policies)


-- ---------- 1. breach alert helper (private — not granted) ----------
-- Resolves the §10 recipients for a suspected-breach report: programme lead,
-- accountable officer and partner consultant — every active assignment of
-- those roles at client scope, at programme scope under this client, or
-- (partner_consultant only) at the owning partner scope. The event lands in
-- the outbox NOW; W1-08's dispatcher sends kind='breach_alert' immediately.
CREATE FUNCTION public.oprecord_emit_breach_alert(p_record uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rec    public.operational_records%ROWTYPE;
  v_pract  uuid;
  v_rcpts  uuid[];
BEGIN
  SELECT * INTO v_rec FROM public.operational_records WHERE id = p_record;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT practice_id INTO v_pract FROM public.client_orgs
   WHERE id = v_rec.client_org_id;

  SELECT array_agg(DISTINCT ra.user_id) INTO v_rcpts
    FROM public.role_assignments ra
   WHERE ra.level IN ('partner','client')
     AND ra.role IN ('programme_lead','accountable_officer','partner_consultant')
     AND ra.start_date <= CURRENT_DATE
     AND (ra.end_date IS NULL OR ra.end_date > CURRENT_DATE)
     AND ( (ra.scope_type = 'client' AND ra.scope_id = v_rec.client_org_id)
        OR (ra.scope_type = 'programme' AND ra.scope_id IN
              (SELECT p.id FROM public.programmes p
                WHERE p.client_org_id = v_rec.client_org_id))
        OR (ra.scope_type = 'partner' AND ra.scope_id = v_pract
            AND ra.role = 'partner_consultant') );

  INSERT INTO public.notification_events (kind, scope, payload)
  VALUES ('breach_alert',
          jsonb_build_object('client_org_id', v_rec.client_org_id,
                             'practice_id',   v_pract),
          jsonb_build_object('record_id',    v_rec.id,
                             'reported_by',  v_rec.reported_by,
                             'reported_at',  v_rec.reported_at,
                             'suspected_on', v_rec.deadline_params->>'suspected_on',
                             'due_date',     v_rec.due_date,
                             'description',  v_rec.description,
                             'recipients',   to_jsonb(COALESCE(v_rcpts,'{}'::uuid[])),
                             'timing',       'immediate'));   -- §10: never the digest
END $$;
COMMENT ON FUNCTION public.oprecord_emit_breach_alert(uuid) IS
  'W1-04: emit the immediate breach_alert notification_event for one '
  'operational_records row (§10 suspected-breach row: PL + AO + partner '
  'consultant, at once — never the daily digest).';


-- ---------- 2. create_operational_record — the generic register write ------
-- payload keys (all optional unless noted):
--   description text · site text · channel text · reported_at timestamptz
--   deadline_rule text (default per type, decision 2) · deadline_params jsonb
--   status text — 'Open' default; 'Closed' is refused here (close RPC only).
CREATE FUNCTION public.create_operational_record(
    p_client_org uuid, p_register_type text, p_payload jsonb DEFAULT '{}')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payload  jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_rule     text;
  v_status   text;
  v_id       uuid;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  -- decision 1: the shipped CHECK vocabulary is authoritative
  IF p_register_type NOT IN ('dsr','breach','disclosure','optout') THEN
    RAISE EXCEPTION 'unknown operational register type "%" — valid types: dsr, breach, disclosure, optout (incidents use ''breach'' per spec §6.2)',
      p_register_type;
  END IF;

  -- FR-OPS-04: any user who can see the client may report a breach;
  -- the other registers need a client write role (W0-02 update-policy set).
  IF p_register_type = 'breach' THEN
    IF NOT (p_client_org IN (SELECT public.allowed_client_orgs())) THEN
      RAISE EXCEPTION 'breach report requires visibility of the client';
    END IF;
  ELSIF NOT public.has_client_role(p_client_org,
      ARRAY['partner_admin','partner_consultant','programme_lead',
            'client_admin','accountable_officer']) THEN
    RAISE EXCEPTION 'register write requires a client write role';
  END IF;

  v_status := COALESCE(v_payload->>'status',
              CASE WHEN p_register_type = 'breach'
                   THEN 'Awaiting decision' ELSE 'Open' END);
  IF v_status NOT IN ('Open','In progress','Awaiting decision') THEN
    RAISE EXCEPTION 'new records open at Open/In progress/Awaiting decision — ''Closed'' goes through close_operational_record (got ''%'')', v_status;
  END IF;

  -- decision 2: per-type default deadline rule; payload may override.
  v_rule := COALESCE(v_payload->>'deadline_rule',
             CASE p_register_type
               WHEN 'dsr'    THEN 'data_subject_request'
               WHEN 'breach' THEN 'breach_notification'
               WHEN 'optout' THEN 'opt_out'
               ELSE NULL END);

  INSERT INTO public.operational_records
      (client_org_id, type, description, reported_at, site, channel,
       deadline_rule, deadline_params, status, outcome)
  VALUES (p_client_org, p_register_type,
          v_payload->>'description',
          COALESCE((v_payload->>'reported_at')::timestamptz, now()),
          v_payload->>'site', v_payload->>'channel',
          v_rule, COALESCE(v_payload->'deadline_params', '{}'::jsonb),
          v_status, v_payload->>'outcome')
  RETURNING id INTO v_id;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = p_client_org;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'operational_record.created',
          jsonb_build_object('record_id', v_id,
                             'client_org_id', p_client_org,
                             'type', p_register_type,
                             'deadline_rule', v_rule));

  -- FR-OPS-04/§10: a suspected breach is alerted AT ONCE, in-transaction.
  IF p_register_type = 'breach' THEN
    PERFORM public.oprecord_emit_breach_alert(v_id);
  END IF;
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.create_operational_record(uuid, text, jsonb) IS
  'W1-04 FR-OPS-01/04: create a client-level operational register record '
  '(dsr|breach|disclosure|optout). Breach reports need only client '
  'visibility (any screen, any user) and emit the immediate breach_alert; '
  'other types need a client write role. due_date is engine-computed.';


-- ---------- 3. record_dsr — FR-OPS-01/02 data subject request --------------
-- kind: access|rectification|erasure|portability|objection|… (free label —
-- the vocabulary varies by jurisdiction pack). received_on is the §9.7
-- anchor; the trigger resolves due_date from the client's jurisdiction pack.
CREATE FUNCTION public.record_dsr(
    p_client_org uuid, p_kind text, p_received_on date,
    p_details text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_received_on IS NULL THEN
    RAISE EXCEPTION 'a DSR needs its received date (the deadline anchor)';
  END IF;
  IF p_kind IS NULL OR btrim(p_kind) = '' THEN
    RAISE EXCEPTION 'a DSR needs a kind (access, rectification, erasure, …)';
  END IF;
  RETURN public.create_operational_record(p_client_org, 'dsr',
    jsonb_build_object(
      'description',    COALESCE(NULLIF(btrim(p_details), ''),
                                 'Data subject request — '||btrim(p_kind)),
      'deadline_rule',  'data_subject_request',
      'deadline_params', jsonb_build_object('received_on', p_received_on,
                                            'kind', btrim(p_kind)),
      'channel',        'register'));
END $$;
COMMENT ON FUNCTION public.record_dsr(uuid, text, date, text) IS
  'W1-04 FR-OPS-01/02: log a data subject request. due_date resolves from '
  'the client''s jurisdiction pack via deadline_rule '
  '''data_subject_request'' — never a hard-coded period.';


-- ---------- 4. record_breach — FR-OPS-03/04 any-screen breach report -------
CREATE FUNCTION public.record_breach(
    p_client_org uuid, p_occurred_on timestamptz, p_summary text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id       uuid;
  v_practice uuid;
BEGIN
  IF p_summary IS NULL OR btrim(p_summary) = '' THEN
    RAISE EXCEPTION 'a breach report needs a summary';
  END IF;
  v_id := public.create_operational_record(p_client_org, 'breach',
    jsonb_build_object(
      'description',    btrim(p_summary),
      'channel',        'in_app',
      'deadline_rule',  'breach_notification',
      'deadline_params', jsonb_build_object(
                            'suspected_on', COALESCE(p_occurred_on, now())::date,
                            'reported_via', 'any_screen'),
      'status',         'Awaiting decision'));

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = p_client_org;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'operational_record.breach_reported',
          jsonb_build_object('record_id', v_id,
                             'client_org_id', p_client_org,
                             'suspected_on', COALESCE(p_occurred_on, now())::date));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.record_breach(uuid, timestamptz, text) IS
  'W1-04 FR-OPS-03/04: any-screen suspected-breach report — any user with '
  'client visibility. Creates the record at Awaiting decision, resolves the '
  'regulator deadline from the pack, and emits the immediate breach_alert.';


-- ---------- 5. record_breach_decision — FR-OPS-03 + FR-ACC-02 (T5) ---------
-- The ONLY writer of regulator_notification. Appends the decision to the
-- jsonb history and stamps the latest at top level (decision 4).
CREATE FUNCTION public.record_breach_decision(
    p_record uuid, p_decision text, p_rationale text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rec  public.operational_records%ROWTYPE;
  v_practice uuid;
  v_entry jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_decision NOT IN ('notified','not_notified','partial') THEN
    RAISE EXCEPTION 'breach decision must be notified|not_notified|partial (got ''%'')', p_decision;
  END IF;
  SELECT * INTO v_rec FROM public.operational_records WHERE id = p_record;
  IF NOT FOUND THEN RAISE EXCEPTION 'operational record % not found', p_record; END IF;
  IF v_rec.type <> 'breach' THEN
    RAISE EXCEPTION 'record % is a ''%'' — breach decisions apply to breach records only', p_record, v_rec.type;
  END IF;
  IF v_rec.status = 'Closed' THEN
    RAISE EXCEPTION 'record % is Closed — no further breach decisions', p_record;
  END IF;
  IF NOT public.is_ao_or_alternate(v_rec.client_org_id) THEN
    RAISE EXCEPTION 'only the accountable officer or named alternate may record a breach notification decision (FR-ACC-02)';
  END IF;

  v_entry := jsonb_build_object('decision',  p_decision,
                                'rationale', p_rationale,
                                'decided_by', auth.uid(),
                                'decided_at', now());

  UPDATE public.operational_records r
     SET regulator_notification =
           jsonb_build_object(
             'decision',   p_decision,
             'rationale',  p_rationale,
             'decided_by', auth.uid(),
             'decided_at', now(),
             'rule',       r.deadline_rule,
             'history',    COALESCE(r.regulator_notification->'history',
                                    '[]'::jsonb) || v_entry),
         status = CASE WHEN r.status = 'Awaiting decision'
                       THEN 'In progress' ELSE r.status END
   WHERE r.id = p_record;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = v_rec.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'operational_record.breach_decision',
          jsonb_build_object('record_id', p_record,
                             'client_org_id', v_rec.client_org_id,
                             'decision', p_decision));
END $$;
COMMENT ON FUNCTION public.record_breach_decision(uuid, text, text) IS
  'W1-04 FR-OPS-03/FR-ACC-02: the AO-or-alternate gate records the '
  'regulator-notification decision (notified|not_notified|partial) — '
  'appended to regulator_notification.history; sole writer of the '
  'write-protected column.';


-- ---------- 6. close_operational_record — allowed transitions only ---------
CREATE FUNCTION public.close_operational_record(
    p_record uuid, p_closure_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rec  public.operational_records%ROWTYPE;
  v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_rec FROM public.operational_records WHERE id = p_record;
  IF NOT FOUND THEN RAISE EXCEPTION 'operational record % not found', p_record; END IF;
  IF v_rec.status = 'Closed' THEN
    RAISE EXCEPTION 'operational record % is already Closed', p_record;
  END IF;
  IF NOT public.has_client_role(v_rec.client_org_id,
      ARRAY['partner_admin','partner_consultant','programme_lead',
            'client_admin','accountable_officer']) THEN
    RAISE EXCEPTION 'closing a register record requires a client write role';
  END IF;
  -- FR-OPS-03: breaches close with lessons learned.
  IF v_rec.type = 'breach' AND NULLIF(btrim(COALESCE(p_closure_note,'')), '') IS NULL THEN
    RAISE EXCEPTION 'closing a breach requires a closure note (lessons learned, FR-OPS-03)';
  END IF;

  UPDATE public.operational_records r
     SET status    = 'Closed',
         closed_on = now(),
         outcome   = CASE
           WHEN NULLIF(btrim(COALESCE(p_closure_note,'')), '') IS NULL
             THEN r.outcome
           WHEN r.outcome IS NULL OR btrim(r.outcome) = ''
             THEN btrim(p_closure_note)
           ELSE r.outcome || E'\n— ' || btrim(p_closure_note)
         END
   WHERE r.id = p_record;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = v_rec.client_org_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'operational_record.closed',
          jsonb_build_object('record_id', p_record,
                             'client_org_id', v_rec.client_org_id,
                             'type', v_rec.type,
                             'closure_note', p_closure_note));
END $$;
COMMENT ON FUNCTION public.close_operational_record(uuid, text) IS
  'W1-04: close an open register record (Open|In progress|Awaiting decision '
  '→ Closed; sole writer of closed_on). Breaches require the lessons-learned '
  'note (FR-OPS-03); the note appends to outcome.';


-- ---------- 7. list_operational_records — paged, scope-checked -------------
CREATE FUNCTION public.list_operational_records(
    p_client_org uuid, p_register_type text DEFAULT NULL,
    p_filters jsonb DEFAULT '{}')
RETURNS SETOF public.operational_records
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.* FROM public.operational_records r
   WHERE r.client_org_id = p_client_org
     AND p_client_org IN (SELECT public.allowed_client_orgs())
     AND (p_register_type IS NULL OR r.type = p_register_type)
     AND (COALESCE(p_filters->>'status','') = '' OR r.status = p_filters->>'status')
     AND (COALESCE(p_filters->>'overdue','') = ''
          OR (r.status <> 'Closed' AND r.due_date IS NOT NULL
              AND r.due_date < CURRENT_DATE) = (p_filters->>'overdue')::boolean)
     AND (p_filters->>'due_before'      IS NULL OR r.due_date <  (p_filters->>'due_before')::date)
     AND (p_filters->>'due_after'       IS NULL OR r.due_date >= (p_filters->>'due_after')::date)
     AND (p_filters->>'reported_after'  IS NULL OR r.reported_at >= (p_filters->>'reported_after')::timestamptz)
     AND (p_filters->>'reported_before' IS NULL OR r.reported_at <  (p_filters->>'reported_before')::timestamptz)
   ORDER BY r.reported_at DESC, r.id
   LIMIT  LEAST(GREATEST(COALESCE((p_filters->>'limit')::int, 50), 1), 200)
   OFFSET GREATEST(COALESCE((p_filters->>'offset')::int, 0), 0)
$$;
COMMENT ON FUNCTION public.list_operational_records(uuid, text, jsonb) IS
  'W1-04: paged register read for one client. filters: status, overdue, '
  'due_before/due_after, reported_after/reported_before, limit (≤200, '
  'default 50), offset. Scope-checked via allowed_client_orgs().';


-- ---------- 8. external providers — the maintenance-input contact book ------
CREATE FUNCTION public.list_external_providers(p_client_org uuid)
RETURNS SETOF public.external_providers
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.* FROM public.external_providers p
   WHERE p.client_org_id = p_client_org
     AND p_client_org IN (SELECT public.allowed_client_orgs())
   ORDER BY p.name
$$;
COMMENT ON FUNCTION public.list_external_providers(uuid) IS
  'W1-04 FR-MNT-04: named external providers for one client (IT provider, '
  'marketing lead, …) — the maintenance-input contact book.';

CREATE FUNCTION public.upsert_external_provider(
    p_client_org uuid, p_name text, p_kind text DEFAULT NULL,
    p_contact_email text DEFAULT NULL, p_channel text DEFAULT NULL,
    p_active boolean DEFAULT true, p_provider_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid; v_practice uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'a provider needs a name';
  END IF;
  IF NOT public.has_client_role(p_client_org,
      ARRAY['partner_admin','partner_consultant','programme_lead','client_admin']) THEN
    RAISE EXCEPTION 'provider write requires a client write role';
  END IF;

  IF p_provider_id IS NULL THEN
    INSERT INTO public.external_providers
        (client_org_id, name, kind, contact_email, channel, active)
    VALUES (p_client_org, btrim(p_name), p_kind, p_contact_email, p_channel,
            COALESCE(p_active, true))
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.external_providers p
       SET name = btrim(p_name), kind = p_kind,
           contact_email = p_contact_email, channel = p_channel,
           active = COALESCE(p_active, p.active)
     WHERE p.id = p_provider_id AND p.client_org_id = p_client_org
    RETURNING p.id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'provider % not found under this client', p_provider_id;
    END IF;
  END IF;

  SELECT practice_id INTO v_practice FROM public.client_orgs
   WHERE id = p_client_org;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'external_provider.upserted',
          jsonb_build_object('provider_id', v_id,
                             'client_org_id', p_client_org,
                             'name', btrim(p_name)));
  RETURN v_id;
END $$;
COMMENT ON FUNCTION public.upsert_external_provider(uuid, text, text, text, text, boolean, uuid) IS
  'W1-04 FR-MNT-03/04: insert or update a named provider contact '
  '(p_provider_id NULL → insert). Write-role gated; audit-logged.';


-- ---------- 9. lock the function surface (W0-00 convention) -----------------
REVOKE EXECUTE ON FUNCTION
  public.oprecord_emit_breach_alert(uuid),
  public.create_operational_record(uuid, text, jsonb),
  public.record_dsr(uuid, text, date, text),
  public.record_breach(uuid, timestamptz, text),
  public.record_breach_decision(uuid, text, text),
  public.close_operational_record(uuid, text),
  public.list_operational_records(uuid, text, jsonb),
  public.list_external_providers(uuid),
  public.upsert_external_provider(uuid, text, text, text, text, boolean, uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.create_operational_record(uuid, text, jsonb),
  public.record_dsr(uuid, text, date, text),
  public.record_breach(uuid, timestamptz, text),
  public.record_breach_decision(uuid, text, text),
  public.close_operational_record(uuid, text),
  public.list_operational_records(uuid, text, jsonb),
  public.list_external_providers(uuid),
  public.upsert_external_provider(uuid, text, text, text, text, boolean, uuid)
TO authenticated;
-- oprecord_emit_breach_alert stays internal — emitted by the definers only.

COMMIT;
