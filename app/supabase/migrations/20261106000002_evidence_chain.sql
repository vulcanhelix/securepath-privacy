-- ============================================================================
-- W1-02 — EVIDENCE CHAIN RPCs
-- (GitHub #16 · spec SP-SPC-PLT-001 §6.2/§9.4/§10, FR-EVD-01..07,
--  FR-ACC-01/02, FR-TPL-07, FR-ONB-05, NFR-09 · plan BUILD_PLAN_R1 W1-02)
-- ============================================================================
--
-- The upload → verify → accept/return chain for programme evidence, plus
-- cross-programme offers. Everything rides the W0-02 spine:
--
--   * evidence_items.review_stage : verification → acceptance → decided
--                                   (this migration adds 'returned' — see below)
--   * evidence_reviews            : append-only verify/accept ledger; the
--                                   trg_evidence_review_gate trigger already
--                                   enforces role + self-review bans on EVERY
--                                   insert — the RPCs repeat the checks so
--                                   callers get precise errors (belt+braces).
--   * trg_evidence_immutable      : NFR-09 — decided evidence is locked;
--                                   extended here to cover 'returned' rows.
--
-- DECISIONS (documented, not bugs):
--
--   * 'returned' is a review_stage, not a reviews-only state. A return is a
--     DECISION: the row is dead and the uploader's correction is a NEW row
--     linked by `supersedes` (NFR-09 "corrections are new versions"). This is
--     why review_stage needed extending — a backward acceptance→verification
--     hop would have broken the forward-only rule and let one row carry two
--     divergent lifecycles.
--   * 'decided' and 'returned' rows are immutable for UPDATE and DELETE alike
--     (trg_evidence_immutable). The audit trail must show what was rejected.
--   * Cross-programme share = NEW evidence_items row in the target programme
--     carrying `source_evidence_id` provenance. The original is never moved —
--     each programme decides independently (FR-TPL-07 "acceptance is still
--     made separately in each programme"). The new row lands at 'acceptance'
--     and is decided by the TARGET programme's AO in the same call — the
--     source programme already ran verification; the target's separate
--     decision IS the AO's offer acceptance.
--   * `outcome` is COMPUTED at acceptance, not supplied: 'closes_finding'
--     when acceptance closes ≥1 register item (§9.4), 'partly_supports' when
--     register-linked but not yet closable, else 'kpi_evidence'.
--   * §9.4 closure: a register item closes when every activity linked to it
--     (register_item_activities) is Complete — items with no linked
--     activities close on direct accepted evidence. Re-opening stays AO-only
--     via trg_register_closure (unchanged).
--   * EV refs are minted per partner (practices.ev_ref_format, printf-style:
--     %s = token = register ref, or 'KPI'/'GEN' when unlinked; %0Nd = seq).
--     Sequence counts prior decided/returned rows for the same register item
--     in the same programme +1 (default format gives EV-<ref>-<seq>,
--     FR-EVD-06). Postgres format() can't do %d, so evidence_format_ref()
--     implements the small printf subset the column contract documents.
--   * upload RPC mirrors the evidence_items INSERT policy exactly (programme
--     write roles OR named activity lead) — callers get the same answer
--     through either path.
--   * The 'note' upload field is a new column; file_key/link are stored
--     unchanged. The actual object upload is app-layer (S3 signed path) —
--     the RPC only validates + records (FR-EVD-02).
--
-- ============================================================================

-- ---------- 1. columns: note (upload context), supersedes (NFR-09
-- versioning), source_evidence_id (cross-programme provenance) ----------
ALTER TABLE public.evidence_items
  ADD COLUMN note                text,                    -- uploader note/context
  ADD COLUMN supersedes          uuid REFERENCES public.evidence_items(id) ON DELETE SET NULL,
  ADD COLUMN source_evidence_id  uuid REFERENCES public.evidence_items(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.evidence_items.note IS
  'Uploader-supplied context (W1-02 upload_evidence).';
COMMENT ON COLUMN public.evidence_items.supersedes IS
  'NFR-09 version chain: corrections are new rows, never edits (W1-02).';
COMMENT ON COLUMN public.evidence_items.source_evidence_id IS
  'FR-TPL-07 cross-programme share provenance: the accepted source item this '
  'row was created from by accept_evidence_offer (W1-02). Definer-only.';

CREATE INDEX evidence_items_source_idx ON public.evidence_items (source_evidence_id)
  WHERE source_evidence_id IS NOT NULL;

-- 'returned' joins the lifecycle (see header DECISIONS)
ALTER TABLE public.evidence_items DROP CONSTRAINT evidence_items_review_stage_check;
ALTER TABLE public.evidence_items ADD CONSTRAINT evidence_items_review_stage_check
  CHECK (review_stage IN ('verification','acceptance','decided','returned'));

-- note + supersedes stay client-writable on the direct-INSERT path (the RPC
-- remains the supported path); source_evidence_id is definer-only provenance.
GRANT INSERT (note, supersedes) ON public.evidence_items TO authenticated;

-- ---------- 2. trg_evidence_immutable: returned is terminal too ----------
CREATE OR REPLACE FUNCTION public.trg_evidence_immutable() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.review_stage IN ('decided','returned') THEN
    RAISE EXCEPTION 'decided or returned evidence is immutable — record a new version instead (NFR-09)';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  -- forward-only stage flow: verification → acceptance → decided|returned
  IF NEW.review_stage IS DISTINCT FROM OLD.review_stage THEN
    IF NOT ( (OLD.review_stage = 'verification' AND NEW.review_stage IN ('acceptance','decided','returned'))
          OR (OLD.review_stage = 'acceptance'   AND NEW.review_stage IN ('decided','returned')) ) THEN
      RAISE EXCEPTION 'evidence review_stage may only move forward';
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION public.trg_evidence_immutable() IS
  'NFR-09 + W1-02: decided AND returned evidence is immutable (UPDATE/DELETE '
  'denied); corrections are new rows via supersedes. Forward-only stage flow.';

-- ---------- 3. private helpers (no public EXECUTE) ----------

-- printf-subset for practices.ev_ref_format: %s token, %0Nd / %Nd / %d seq,
-- %% literal. Postgres format() lacks %d, hence this.
CREATE FUNCTION public.evidence_format_ref(p_fmt text, p_token text, p_seq int)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_out  text := '';
    v_i    int  := 1;
    v_len  int  := length(p_fmt);
    v_rest text;
    v_w    int;
BEGIN
    WHILE v_i <= v_len LOOP
        IF substr(p_fmt, v_i, 1) = '%' THEN
            v_rest := substr(p_fmt, v_i + 1);
            IF v_rest ~ '^0[0-9]+d' THEN                       -- %03d
                v_w   := (regexp_match(v_rest, '^0([0-9]+)d'))[1]::int;
                v_out := v_out || lpad(p_seq::text, v_w, '0');
                v_i   := v_i + 2 + length((regexp_match(v_rest, '^0[0-9]+'))[1]);
            ELSIF v_rest ~ '^[0-9]+d' THEN                     -- %3d (space-pad)
                v_w   := (regexp_match(v_rest, '^([0-9]+)d'))[1]::int;
                v_out := v_out || rpad(p_seq::text, v_w);
                v_i   := v_i + 2 + length((regexp_match(v_rest, '^[0-9]+'))[1]);
            ELSIF v_rest ~ '^d' THEN                           -- %d
                v_out := v_out || p_seq::text;
                v_i   := v_i + 2;
            ELSIF v_rest ~ '^s' THEN                           -- %s
                v_out := v_out || p_token;
                v_i   := v_i + 2;
            ELSIF v_rest ~ '^%' THEN                           -- %%
                v_out := v_out || '%';
                v_i   := v_i + 2;
            ELSE                                               -- unknown spec: literal %
                v_out := v_out || '%';
                v_i   := v_i + 1;
            END IF;
        ELSE
            v_out := v_out || substr(p_fmt, v_i, 1);
            v_i := v_i + 1;
        END IF;
    END LOOP;
    RETURN v_out;
END $$;

-- mint the next evidence ref for (programme, register item) — FR-EVD-06
CREATE FUNCTION public.evidence_next_ref(p_programme uuid, p_register_item uuid,
                                         p_outcome text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_fmt   text;
    v_token text;
    v_seq   int;
BEGIN
    SELECT pr.ev_ref_format INTO v_fmt
      FROM public.programmes p
      JOIN public.client_orgs c  ON c.id  = p.client_org_id
      JOIN public.practices   pr ON pr.id = c.practice_id
     WHERE p.id = p_programme;
    v_fmt := coalesce(v_fmt, 'EV-%s-%03d');
    v_token := coalesce(
        (SELECT ref FROM public.register_items WHERE id = p_register_item),
        CASE WHEN p_outcome = 'kpi_evidence' THEN 'KPI' ELSE 'GEN' END);
    SELECT count(*) + 1 INTO v_seq
      FROM public.evidence_items
     WHERE programme_id = p_programme
       AND evidence_ref IS NOT NULL
       AND register_item_id IS NOT DISTINCT FROM p_register_item;
    RETURN public.evidence_format_ref(v_fmt, v_token, v_seq);
END $$;

-- append a notification_events row (outbox; §10)
CREATE FUNCTION public.evidence_notify(p_kind text, p_scope jsonb, p_payload jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    INSERT INTO public.notification_events (kind, scope, payload)
    VALUES (p_kind, p_scope, p_payload);
$$;

-- shared acceptance ritual: compute outcome, mint ref, mark decided, close
-- eligible register items (§9.4). Caller RPCs have already done the role
-- gates + written the 'accept' review row.
CREATE FUNCTION public.evidence_finalize_acceptance(p_evidence_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev      public.evidence_items%ROWTYPE;
    v_client  uuid;
    v_outcome text;
    v_ref     text;
    v_reg     record;
    v_closable uuid[] := '{}';
    v_any_reg boolean := false;
    v_rid     uuid;
BEGIN
    SELECT * INTO v_ev FROM public.evidence_items WHERE id = p_evidence_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;

    -- candidate register items: direct link + items linked to the evidence's
    -- activity via the m2m
    FOR v_reg IN
        SELECT ri.id, ri.status FROM public.register_items ri
         WHERE ri.id = v_ev.register_item_id
        UNION
        SELECT ri.id, ri.status FROM public.register_items ri
         JOIN public.register_item_activities ria
           ON ria.register_item_id = ri.id
        WHERE ria.activity_id = v_ev.activity_id
    LOOP
        v_any_reg := true;
        IF v_reg.status <> 'Closed'
           AND NOT EXISTS (
               SELECT 1
                 FROM public.register_item_activities ria2
                 JOIN public.activities a ON a.id = ria2.activity_id
                WHERE ria2.register_item_id = v_reg.id
                  AND a.status <> 'Complete') THEN
            v_closable := v_closable || v_reg.id;
        END IF;
    END LOOP;

    v_outcome := CASE WHEN coalesce(array_length(v_closable, 1), 0) > 0
                      THEN 'closes_finding'
                      WHEN v_any_reg THEN 'partly_supports'
                      ELSE 'kpi_evidence' END;
    v_ref := public.evidence_next_ref(v_ev.programme_id, v_ev.register_item_id,
                                      v_outcome);

    UPDATE public.evidence_items
       SET review_stage = 'decided', outcome = v_outcome, evidence_ref = v_ref
     WHERE id = p_evidence_id;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_ev.programme_id;

    FOREACH v_rid IN ARRAY v_closable LOOP
        UPDATE public.register_items
           SET status = 'Closed',
               accepted_on = now(),
               accepted_by = auth.uid(),
               accepted_evidence_refs =
                   coalesce(accepted_evidence_refs, '{}'::text[]) || v_ref
         WHERE id = v_rid;
        PERFORM public.evidence_notify('register_item_closed',
            jsonb_build_object('programme_id', v_ev.programme_id,
                               'client_org_id', v_client),
            jsonb_build_object('register_item_id', v_rid,
                               'evidence_id', p_evidence_id,
                               'evidence_ref', v_ref,
                               'accepted_by', auth.uid()));
    END LOOP;

    RETURN jsonb_build_object('evidence_id', p_evidence_id,
                            'evidence_ref', v_ref,
                            'outcome', v_outcome,
                            'closed_register_items', to_jsonb(v_closable));
END $$;

-- ---------- 4. the RPCs ----------

-- upload_evidence — FR-EVD-01/02: validate + record at 'verification'
-- (pending review). The object itself is uploaded app-layer to the evidence
-- store; this records the storage key or a link.
CREATE FUNCTION public.upload_evidence(
    p_activity_id      uuid DEFAULT NULL,
    p_register_item_id uuid DEFAULT NULL,
    p_file_key         text DEFAULT NULL,
    p_link             text DEFAULT NULL,
    p_note             text DEFAULT NULL,
    p_site             text DEFAULT NULL,
    p_supersedes       uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_programme uuid;
    v_reg_prog  uuid;
    v_client    uuid;
    v_id        uuid;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
    IF p_activity_id IS NULL AND p_register_item_id IS NULL THEN
        RAISE EXCEPTION 'evidence must link to an activity or a register item';
    END IF;
    IF p_file_key IS NULL AND p_link IS NULL THEN
        RAISE EXCEPTION 'evidence requires a file or a link (FR-EVD-01)';
    END IF;

    IF p_activity_id IS NOT NULL THEN
        SELECT programme_id INTO v_programme
          FROM public.activities WHERE id = p_activity_id;
        IF v_programme IS NULL THEN RAISE EXCEPTION 'activity not found'; END IF;
    END IF;
    IF p_register_item_id IS NOT NULL THEN
        SELECT programme_id INTO v_reg_prog
          FROM public.register_items WHERE id = p_register_item_id;
        IF v_reg_prog IS NULL THEN RAISE EXCEPTION 'register item not found'; END IF;
        IF v_programme IS NOT NULL AND v_programme <> v_reg_prog THEN
            RAISE EXCEPTION 'activity and register item must belong to the same programme';
        END IF;
        v_programme := v_reg_prog;
    END IF;

    -- same gate as the evidence_items INSERT policy
    IF NOT public.has_programme_role(v_programme,
             ARRAY['partner_admin','partner_consultant','programme_lead',
                   'client_admin','workstream_lead','external_provider'])
       AND NOT (p_activity_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.activities a
                 WHERE a.id = p_activity_id AND auth.uid() = ANY(a.leads))) THEN
        RAISE EXCEPTION 'caller may not upload evidence to this programme';
    END IF;

    IF p_supersedes IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.evidence_items s
                        WHERE s.id = p_supersedes
                          AND s.programme_id = v_programme) THEN
        RAISE EXCEPTION 'superseded evidence must belong to the same programme';
    END IF;

    INSERT INTO public.evidence_items
        (programme_id, activity_id, register_item_id, site, file_key, link,
         note, supersedes, uploaded_by, review_stage)
    VALUES (v_programme, p_activity_id, p_register_item_id, p_site, p_file_key,
            p_link, p_note, p_supersedes, auth.uid(), 'verification')
    RETURNING id INTO v_id;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_programme;
    PERFORM public.evidence_notify('evidence_uploaded',
        jsonb_build_object('programme_id', v_programme, 'client_org_id', v_client),
        jsonb_build_object('evidence_id', v_id, 'uploaded_by', auth.uid(),
                           'activity_id', p_activity_id,
                           'register_item_id', p_register_item_id,
                           'supersedes', p_supersedes));
    RETURN v_id;
END $$;

-- verify_evidence — FR-EVD-03 reviewer gate. verdict 'approved' → acceptance
-- queue; 'returned' → back to the uploader (terminal row, new version flow).
CREATE FUNCTION public.verify_evidence(
    p_evidence_id uuid,
    p_verdict     text,
    p_comment     text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev     public.evidence_items%ROWTYPE;
    v_client uuid;
    v_review uuid;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
    IF p_verdict IS NULL OR p_verdict NOT IN ('approved','returned') THEN
        RAISE EXCEPTION 'verdict must be approved or returned';
    END IF;

    SELECT * INTO v_ev FROM public.evidence_items
     WHERE id = p_evidence_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;
    IF v_ev.review_stage <> 'verification' THEN
        RAISE EXCEPTION 'evidence is not awaiting verification (stage %)', v_ev.review_stage;
    END IF;
    -- FR-ACC-01 double-check (the review-gate trigger enforces it too)
    IF v_ev.uploaded_by = auth.uid() THEN
        RAISE EXCEPTION 'nobody may verify evidence they uploaded (FR-ACC-01)';
    END IF;
    IF NOT public.has_programme_role(v_ev.programme_id,
             ARRAY['partner_admin','partner_consultant','programme_lead']) THEN
        RAISE EXCEPTION 'only the programme lead or partner consultant may verify evidence (FR-EVD-03)';
    END IF;

    IF p_verdict = 'returned' THEN
        RETURN public.return_evidence(p_evidence_id, ARRAY[p_comment]);
    END IF;

    INSERT INTO public.evidence_reviews (evidence_item_id, stage, decision, reasons)
    VALUES (p_evidence_id, 'verify', 'verified',
            CASE WHEN p_comment IS NULL OR btrim(p_comment) = ''
                 THEN '{}'::text[] ELSE ARRAY[p_comment] END)
    RETURNING id INTO v_review;

    UPDATE public.evidence_items
       SET review_stage = 'acceptance'
     WHERE id = p_evidence_id;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_ev.programme_id;
    -- §10 "Evidence awaiting decision" → the accountable officer's queue
    PERFORM public.evidence_notify('evidence_awaiting_decision',
        jsonb_build_object('programme_id', v_ev.programme_id,
                           'client_org_id', v_client),
        jsonb_build_object('evidence_id', p_evidence_id,
                           'verified_by', auth.uid()));
    RETURN v_review;
END $$;

-- return_evidence — reviewer (verification stage) or AO/alternate (acceptance
-- stage) returns with mandatory reasons. Terminal: the fix is a new version.
CREATE FUNCTION public.return_evidence(
    p_evidence_id uuid,
    p_reasons     text[]
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev     public.evidence_items%ROWTYPE;
    v_client uuid;
    v_review uuid;
    v_stage  text;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
    IF p_reasons IS NULL OR coalesce(array_length(p_reasons, 1), 0) = 0
       OR EXISTS (SELECT 1 FROM unnest(p_reasons) r WHERE r IS NULL OR btrim(r) = '') THEN
        RAISE EXCEPTION 'returning evidence requires reasons (FR-EVD-05)';
    END IF;

    SELECT * INTO v_ev FROM public.evidence_items
     WHERE id = p_evidence_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;
    IF v_ev.review_stage NOT IN ('verification','acceptance') THEN
        RAISE EXCEPTION 'evidence is already decided/returned (stage %)', v_ev.review_stage;
    END IF;
    IF v_ev.uploaded_by = auth.uid() THEN
        RAISE EXCEPTION 'nobody may review evidence they uploaded (FR-ACC-01)';
    END IF;

    v_stage := CASE v_ev.review_stage
                 WHEN 'verification' THEN 'verify' ELSE 'accept' END;
    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_ev.programme_id;

    -- stage-shaped role gate (mirrors the review-gate trigger)
    IF v_stage = 'verify'
       AND NOT public.has_programme_role(v_ev.programme_id,
             ARRAY['partner_admin','partner_consultant','programme_lead']) THEN
        RAISE EXCEPTION 'only the programme lead or partner consultant may return evidence at verification';
    END IF;
    IF v_stage = 'accept' AND NOT public.is_ao_or_alternate(v_client) THEN
        RAISE EXCEPTION 'only the accountable officer or named alternate may return evidence at acceptance';
    END IF;

    INSERT INTO public.evidence_reviews (evidence_item_id, stage, decision, reasons)
    VALUES (p_evidence_id, v_stage, 'returned', p_reasons)
    RETURNING id INTO v_review;

    UPDATE public.evidence_items
       SET review_stage = 'returned'
     WHERE id = p_evidence_id;

    -- §10 "Evidence returned" → the uploader
    PERFORM public.evidence_notify('evidence_returned',
        jsonb_build_object('programme_id', v_ev.programme_id,
                           'client_org_id', v_client,
                           'user_id', v_ev.uploaded_by),
        jsonb_build_object('evidence_id', p_evidence_id,
                           'returned_by', auth.uid(),
                           'stage', v_stage,
                           'reasons', to_jsonb(p_reasons)));
    RETURN v_review;
END $$;

-- accept_evidence — FR-EVD-04/05, FR-ACC-02, FR-EVD-07, §9.4 closure.
CREATE FUNCTION public.accept_evidence(p_evidence_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev     public.evidence_items%ROWTYPE;
    v_client uuid;
    v_review uuid;
    v_led    boolean;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

    SELECT * INTO v_ev FROM public.evidence_items
     WHERE id = p_evidence_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;
    IF v_ev.review_stage <> 'acceptance' THEN
        RAISE EXCEPTION 'evidence is not awaiting acceptance (stage %)', v_ev.review_stage;
    END IF;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_ev.programme_id;

    -- FR-ACC-01: never your own upload (checked first so the uploader gets
    -- the precise denial, matching verify_evidence)
    IF v_ev.uploaded_by = auth.uid() THEN
        RAISE EXCEPTION 'nobody may accept evidence they uploaded (FR-ACC-01)';
    END IF;
    -- FR-ACC-02: AO or named alternate only (RPC-level; trigger re-checks)
    IF NOT public.is_ao_or_alternate(v_client) THEN
        RAISE EXCEPTION 'only the accountable officer or named alternate may accept evidence (FR-ACC-02)';
    END IF;
    -- FR-EVD-07: where the AO led the work, the decision goes to the named
    -- alternate. "Led" = listed activity lead or register-item lead.
    SELECT (v_ev.activity_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM public.activities a
               WHERE a.id = v_ev.activity_id AND auth.uid() = ANY(a.leads)))
        OR (v_ev.register_item_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM public.register_items r
               WHERE r.id = v_ev.register_item_id AND r.lead = auth.uid()))
      INTO v_led;
    IF v_led
       AND NOT public.holds_designation(v_client,
                 ARRAY['named_alternate','deputy_information_officer','dpo']) THEN
        RAISE EXCEPTION 'the accountable officer led this work — the decision goes to a named alternate (FR-EVD-07)';
    END IF;

    INSERT INTO public.evidence_reviews (evidence_item_id, stage, decision)
    VALUES (p_evidence_id, 'accept', 'accepted')
    RETURNING id INTO v_review;

    v_result := public.evidence_finalize_acceptance(p_evidence_id);

    PERFORM public.evidence_notify('evidence_accepted',
        jsonb_build_object('programme_id', v_ev.programme_id,
                           'client_org_id', v_client),
        jsonb_build_object('evidence_id', p_evidence_id,
                           'accepted_by', auth.uid(),
                           'review_id', v_review)
        || (v_result - 'evidence_id'));
    RETURN v_result || jsonb_build_object('review_id', v_review);
END $$;

-- offer_evidence_to_programme — FR-TPL-07/FR-ONB-05: offer ACCEPTED evidence
-- to another programme OF THE SAME CLIENT. Writes a pending offer row; the
-- target's AO decides via accept_evidence_offer.
CREATE FUNCTION public.offer_evidence_to_programme(
    p_evidence_id        uuid,
    p_target_programme_id uuid,
    p_mapped_requirement text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ev      public.evidence_items%ROWTYPE;
    v_src_client uuid;
    v_tgt_client uuid;
    v_offer   uuid;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

    SELECT * INTO v_ev FROM public.evidence_items WHERE id = p_evidence_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence item not found'; END IF;
    IF v_ev.review_stage <> 'decided' THEN
        RAISE EXCEPTION 'only accepted (decided) evidence can be offered (FR-TPL-07)';
    END IF;

    IF NOT public.has_programme_role(v_ev.programme_id,
             ARRAY['partner_admin','partner_consultant','programme_lead',
                   'client_admin']) THEN
        RAISE EXCEPTION 'caller may not offer evidence from this programme';
    END IF;

    SELECT client_org_id INTO v_src_client
      FROM public.programmes WHERE id = v_ev.programme_id;
    SELECT client_org_id INTO v_tgt_client
      FROM public.programmes WHERE id = p_target_programme_id;
    IF v_tgt_client IS NULL THEN RAISE EXCEPTION 'target programme not found'; END IF;
    IF v_tgt_client <> v_src_client THEN
        RAISE EXCEPTION 'evidence may only be offered to another programme of the same client (FR-TPL-07)';
    END IF;
    IF EXISTS (SELECT 1 FROM public.evidence_offers o
                WHERE o.evidence_item_id = p_evidence_id
                  AND o.to_programme_id = p_target_programme_id
                  AND o.outcome IS NULL) THEN
        RAISE EXCEPTION 'a pending offer for this evidence already exists for that programme';
    END IF;

    INSERT INTO public.evidence_offers
        (evidence_item_id, to_programme_id, mapped_requirement)
    VALUES (p_evidence_id, p_target_programme_id, p_mapped_requirement)
    RETURNING id INTO v_offer;

    PERFORM public.evidence_notify('evidence_offered',
        jsonb_build_object('programme_id', p_target_programme_id,
                           'client_org_id', v_tgt_client),
        jsonb_build_object('offer_id', v_offer,
                           'evidence_id', p_evidence_id,
                           'from_programme_id', v_ev.programme_id,
                           'offered_by', auth.uid()));
    RETURN v_offer;
END $$;

-- accept_evidence_offer — the target programme's AO accepts an offered item.
-- Creates a NEW evidence_items row in the target carrying provenance, then
-- runs the acceptance ritual there (mint ref, §9.4 closure). The source row
-- is never moved or altered.
CREATE FUNCTION public.accept_evidence_offer(
    p_offer_id         uuid,
    p_activity_id      uuid DEFAULT NULL,
    p_register_item_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_offer   public.evidence_offers%ROWTYPE;
    v_src     public.evidence_items%ROWTYPE;
    v_client  uuid;
    v_new     uuid;
    v_review  uuid;
    v_result  jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

    SELECT * INTO v_offer FROM public.evidence_offers
     WHERE id = p_offer_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'evidence offer not found'; END IF;
    IF v_offer.outcome IS NOT NULL THEN
        RAISE EXCEPTION 'evidence offer already decided';
    END IF;

    SELECT * INTO v_src FROM public.evidence_items
     WHERE id = v_offer.evidence_item_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'offered evidence no longer exists'; END IF;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = v_offer.to_programme_id;

    IF v_src.uploaded_by = auth.uid() THEN
        RAISE EXCEPTION 'nobody may accept evidence they uploaded (FR-ACC-01)';
    END IF;
    IF NOT public.is_ao_or_alternate(v_client) THEN
        RAISE EXCEPTION 'only the accountable officer or named alternate may accept an evidence offer (FR-ACC-02)';
    END IF;

    -- new row in the target programme, provenance to the source (never moved)
    INSERT INTO public.evidence_items
        (programme_id, activity_id, register_item_id, site, file_key, link,
         note, source_evidence_id, uploaded_by, review_stage)
    VALUES (v_offer.to_programme_id, p_activity_id, p_register_item_id,
            v_src.site, v_src.file_key, v_src.link, v_src.note,
            v_src.id, v_src.uploaded_by, 'acceptance')
    RETURNING id INTO v_new;

    INSERT INTO public.evidence_reviews (evidence_item_id, stage, decision)
    VALUES (v_new, 'accept', 'accepted')
    RETURNING id INTO v_review;

    UPDATE public.evidence_offers
       SET outcome = 'accepted'
     WHERE id = p_offer_id;              -- trigger stamps decided_by/decided_at

    v_result := public.evidence_finalize_acceptance(v_new);

    PERFORM public.evidence_notify('evidence_offer_accepted',
        jsonb_build_object('programme_id', v_src.programme_id,
                           'client_org_id',
                           (SELECT client_org_id FROM public.programmes
                             WHERE id = v_src.programme_id)),
        jsonb_build_object('offer_id', p_offer_id,
                           'evidence_id', v_src.id,
                           'new_evidence_id', v_new,
                           'to_programme_id', v_offer.to_programme_id,
                           'decided_by', auth.uid()));
    RETURN v_result || jsonb_build_object('offer_id', p_offer_id,
                                          'review_id', v_review);
END $$;

-- list_pending_reviews — the evidence queue (W2-06). Two sets:
--   verify: items awaiting verification the reviewer could act on
--           (not their own uploads);
--   accept: items awaiting the AO decision (flagged requires_alternate
--           where FR-EVD-07 sends the decision to the named alternate).
-- Role eligibility for each set is resolved for the CALLING user (the
-- predicates are auth.uid()-keyed); p_reviewer only controls the
-- not-own-upload filter and defaults to the caller.
CREATE FUNCTION public.list_pending_reviews(
    p_programme_id uuid,
    p_reviewer     uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_reviewer   uuid := coalesce(p_reviewer, auth.uid());
    v_client     uuid;
    v_caller_ao  boolean;
    v_caller_alt boolean;
    v_can_verify boolean;
    v_verify     jsonb;
    v_accept     jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
    IF p_programme_id NOT IN (SELECT public.allowed_programmes()) THEN
        RAISE EXCEPTION 'programme not visible to caller';
    END IF;

    SELECT client_org_id INTO v_client
      FROM public.programmes WHERE id = p_programme_id;
    v_caller_ao  := public.is_ao_or_alternate(v_client);
    -- caller-keyed (the predicate reads auth.uid()); when p_reviewer differs
    -- from the caller the requires_alternate flag is approximate — documented.
    v_caller_alt := public.holds_designation(v_client,
                      ARRAY['named_alternate','deputy_information_officer','dpo']);
    v_can_verify := public.has_programme_role(p_programme_id,
                      ARRAY['partner_admin','partner_consultant','programme_lead']);

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY x.uploaded_at), '[]'::jsonb)
      INTO v_verify
      FROM (SELECT e.id, e.activity_id, e.register_item_id, e.site, e.file_key,
                   e.link, e.note, e.uploaded_by, e.uploaded_at,
                   a.ref AS activity_ref, r.ref AS register_ref
              FROM public.evidence_items e
              LEFT JOIN public.activities     a ON a.id = e.activity_id
              LEFT JOIN public.register_items r ON r.id = e.register_item_id
             WHERE e.programme_id = p_programme_id
               AND e.review_stage = 'verification'
               AND e.uploaded_by IS DISTINCT FROM v_reviewer) x;

    SELECT coalesce(jsonb_agg(row_to_json(x) ORDER BY x.uploaded_at), '[]'::jsonb)
      INTO v_accept
      FROM (SELECT e.id, e.activity_id, e.register_item_id, e.site, e.file_key,
                   e.link, e.note, e.uploaded_by, e.uploaded_at,
                   a.ref AS activity_ref, r.ref AS register_ref,
                   (EXISTS (SELECT 1 FROM public.activities la
                             WHERE la.id = e.activity_id
                               AND v_reviewer = ANY(la.leads))
                    OR EXISTS (SELECT 1 FROM public.register_items lr
                                WHERE lr.id = e.register_item_id
                                  AND lr.lead = v_reviewer))
                     AND NOT v_caller_alt
                    AS requires_alternate
              FROM public.evidence_items e
              LEFT JOIN public.activities     a ON a.id = e.activity_id
              LEFT JOIN public.register_items r ON r.id = e.register_item_id
             WHERE e.programme_id = p_programme_id
               AND e.review_stage = 'acceptance'
               AND e.uploaded_by IS DISTINCT FROM v_reviewer) x;

    RETURN jsonb_build_object(
        'programme_id', p_programme_id,
        'reviewer', v_reviewer,
        'caller_can_verify', v_can_verify,
        'caller_is_ao_or_alternate', v_caller_ao,
        'verify', v_verify,
        'accept', v_accept);
END $$;

-- ---------- 5. execution surface ----------
REVOKE EXECUTE ON FUNCTION
  public.evidence_format_ref(text, text, int),
  public.evidence_next_ref(uuid, uuid, text),
  public.evidence_notify(text, jsonb, jsonb),
  public.evidence_finalize_acceptance(uuid),
  public.upload_evidence(uuid, uuid, text, text, text, text, uuid),
  public.verify_evidence(uuid, text, text),
  public.return_evidence(uuid, text[]),
  public.accept_evidence(uuid),
  public.offer_evidence_to_programme(uuid, uuid, text),
  public.accept_evidence_offer(uuid, uuid, uuid),
  public.list_pending_reviews(uuid, uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.upload_evidence(uuid, uuid, text, text, text, text, uuid),
  public.verify_evidence(uuid, text, text),
  public.return_evidence(uuid, text[]),
  public.accept_evidence(uuid),
  public.offer_evidence_to_programme(uuid, uuid, text),
  public.accept_evidence_offer(uuid, uuid, uuid),
  public.list_pending_reviews(uuid, uuid)
TO authenticated;
