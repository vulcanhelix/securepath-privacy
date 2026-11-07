-- ============================================================================
-- W3-01 — GENERAL IMPORT FRAMEWORK: versioned import_run/import_row model,
-- upload → row-level validation → dry-run preview → commit → provenance
-- (GitHub #42 · spec SP-SPC-PLT-001 §13.1 FR-IMP-01/02/04/05)
-- ============================================================================
--
-- W0-03 (000004) shipped the import_runs/import_rows TABLES for FR-IMP-05
-- ("preview + rows rejected with reasons before anything is written") and
-- W0-04 (000011) writes them for the assessment-session findings route. This
-- migration EXTENDS that model into the general file-import framework —
-- deliberately NOT a parallel table set: one audit trail for every §13.1
-- import route (findings, assessment_workbook, tracker, template,
-- portal_api, and now documents).
--
-- --------------------------- LIFECYCLE --------------------------------------
--   import_begin    upload parsed file rows → run 'received', rows 'pending'
--   import_preview  dry-run: validate every row (ok|rejected + reason),
--                   diff against the target (create | exists) → 'previewed'
--   import_commit   apply ok rows with import_run_id provenance → 'committed'
--   import_abandon  received|previewed|failed → 'abandoned'
-- committed and abandoned runs (and their rows) are IMMUTABLE on every write
-- path — that is the "versioned" part: a re-import is a NEW run that
-- reconciles to the same entities, never an edit of history. The
-- trg_import_*_guard triggers are unconditional (the codebase's convention:
-- definer RPCs are trusted code and enforce callers in-body). To make an
-- unconditional guard possible, import_assessment_findings is CREATE OR
-- REPLACEd below (§9) so it writes its run 'received' → rows → 'committed'
-- instead of inserting 'committed' then updating — identical results, the
-- ordering the versioning model needs. DELETE is left unrestricted: app
-- roles hold no DELETE grant on either table anyway, and the suites'
-- superuser teardown keeps working.
--
-- --------------------------- DECISIONS ---------------------------------------
-- 1. RUN SHAPE: +programme_id (import target — W0-03/W0-04 runs are
--    programme-agnostic or carry it in preview; backfilled there), +file_name,
--    +file_hash (informational dedupe aid), +committed_by/at. New columns get
--    NO column grants → write-protected, same convention as W0-04.
-- 2. ROW STATUS += 'pending' (parsed, awaiting validation) and 'skipped'
--    (valid but deliberately unapplied — e.g. committed rows that lost their
--    parse payload). The W0-03 reject-reason CHECK is re-scoped to
--    status='rejected' only.
-- 3. KIND: the register-items CSV route IS §13.1 'findings' (FR-IMP-01:
--    "reference, finding, priority, assessment window, lead"). 'documents'
--    is added to the vocabulary for the FR-DOC route that lands after this
--    session; begin() raises a clear 'not wired' error for every kind except
--    'findings' so the framework fails honestly instead of half-applying.
-- 4. VALIDATION is server-side (import_parse_finding_row): the UI canonicalises
--    CSV headers but the DB re-derives every field from raw — client input is
--    never trusted. Required: ref (≤64), finding. Normalised: priority
--    (case-insensitive → High|Medium|Low). Optional: assessment_window,
--    planned_close_week (int ≥ 1), lead (a users.email → lead uuid;
--    unresolvable = reject). In-file duplicate ref → rejected (first wins).
--    Ref already in the programme → 'exists' outcome (mapped at commit to the
--    existing item — the idempotency key is (programme_id, ref), the same
--    uniqueness create_register_item enforces).
-- 5. PREVIEW/ COMMIT GUARD = has_programme_role(programme,
--    ['partner_admin','partner_consultant']) — identical to W0-04's import
--    gate. Runs without a programme fall back to the partner-scope variant.
--    Commit additionally re-locks the programme FOR UPDATE so concurrent
--    imports/register writes serialise on the ref dedupe check, and rejects
--    a closed programme.
-- 6. PROVENANCE + AUDIT: register_items.import_run_id names the run that
--    created the finding (import_rows.mapped_entity = 'register_items:<id>'
--    carries the row-level lineage, W0-04 convention). Audit actions:
--    import.run_created / import.previewed / import.committed /
--    import.abandoned, all carrying import_run_id.
-- 7. IDEMPOTENT RE-RUNS: re-importing the same file creates a new run whose
--    rows all resolve 'already_imported' — no duplicate register_items.
--    Re-committing a committed run is a no-op returning the stored result.
-- 8. READ SURFACE: the W0-03 partner-scope policies stand; ADDED a
--    programme-scope read (programme_id IN allowed_programmes()) so
--    programme/client-scoped callers (e.g. the client-scope consultant)
--    can see their own runs and rows. import_run_detail() is the read RPC
--    for callers without table visibility.
--
-- HARD RULES honoured: every SECURITY DEFINER guards tenant scope in its
-- body (auth.uid() NULL → reject; allowed_client_orgs / has_programme_role /
-- has_partner_role); tenant ids derived server-side (partner_id comes from
-- the programme's client, never the payload); write surfaces stay definer-
-- only (new columns get no grants); W0-04 untouched — its RPC still inserts
-- runs+rows on the trusted path.
-- ============================================================================

BEGIN;

-- ---------- 1. import_runs: programme/file linkage + commit record ----------

ALTER TABLE public.import_runs
  ADD COLUMN programme_id uuid REFERENCES public.programmes(id) ON DELETE SET NULL,
  ADD COLUMN file_name    text,
  ADD COLUMN file_hash    text,
  ADD COLUMN committed_by uuid REFERENCES public.users(id),
  ADD COLUMN committed_at timestamptz;

COMMENT ON COLUMN public.import_runs.programme_id IS
  'W3-01: the programme a file import targets (NULL on W0-03 template / '
  'unlinked runs; backfilled from preview->>programme_id for W0-04 session '
  'imports). Written only by import RPCs — no column grant.';
COMMENT ON COLUMN public.import_runs.file_name IS
  'W3-01: uploaded file display name (audit). Write-protected.';
COMMENT ON COLUMN public.import_runs.file_hash IS
  'W3-01: sha256 (hex) of the uploaded file — informational idempotency aid; '
  'duplicate-file re-imports are still allowed, they reconcile to the same '
  'entities. Write-protected.';
COMMENT ON COLUMN public.import_runs.committed_by IS
  'W3-01: who committed the run. Write-protected.';
COMMENT ON COLUMN public.import_runs.committed_at IS
  'W3-01: when the run committed. Write-protected.';

-- backfill the W0-04 runs (committed before the stamp existed)
UPDATE public.import_runs
   SET committed_at = created_at, committed_by = created_by
 WHERE status = 'committed' AND committed_at IS NULL;
UPDATE public.import_runs
   SET programme_id = (preview->>'programme_id')::uuid
 WHERE programme_id IS NULL
   AND (preview->>'programme_id') ~ '^[0-9a-fA-F-]{36}$';
CREATE INDEX import_runs_programme_idx ON public.import_runs (programme_id)
  WHERE programme_id IS NOT NULL;

-- kind vocabulary += 'documents' (the FR-DOC import route lands after W3-01)
ALTER TABLE public.import_runs DROP CONSTRAINT IF EXISTS import_runs_kind_check;
ALTER TABLE public.import_runs ADD CONSTRAINT import_runs_kind_check
  CHECK (kind IN ('findings','assessment_workbook','tracker','template',
                  'portal_api','documents'));

-- ---------- 2. import_rows.status += pending|skipped; reject-reason rescoped --
-- Drop whatever CHECK constraints exist (auto-names vary), then re-add the
-- widened pair. UNIQUE (import_run_id, row_no) is contype 'u' — untouched.
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'public.import_rows'::regclass AND contype = 'c' LOOP
    EXECUTE format('ALTER TABLE public.import_rows DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;
ALTER TABLE public.import_rows ADD CONSTRAINT import_rows_status_check
  CHECK (status IN ('pending','ok','rejected','skipped'));
ALTER TABLE public.import_rows ADD CONSTRAINT import_rows_reject_reason_check
  CHECK (status <> 'rejected' OR reject_reason IS NOT NULL);
COMMENT ON COLUMN public.import_rows.status IS
  'pending (parsed, awaiting validation) | ok (valid — created or matched at '
  'commit, raw->_outcome says which) | rejected (invalid, reason mandatory) | '
  'skipped (valid but deliberately unapplied).';


-- ---------- 3. register_items: import provenance (decision 6) ----------
ALTER TABLE public.register_items
  ADD COLUMN import_run_id uuid REFERENCES public.import_runs(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.register_items.import_run_id IS
  'W3-01 provenance: the import run that created this finding '
  '(import_commit). Write-protected — no column grant.';
CREATE INDEX register_items_import_run_idx ON public.register_items (import_run_id)
  WHERE import_run_id IS NOT NULL;


-- ---------- 4. versioning guards (unconditional — see header) ----------
--
-- Transition matrix on import_runs:
--   received  → previewed | committed | abandoned | failed
--   previewed → previewed | committed | abandoned | failed
--   failed    → abandoned
--   committed | abandoned → terminal (immutable record)
-- commit requires the committed_by/at stamps — authenticated holds no grant
-- on those columns, so app callers can never commit a run by direct UPDATE;
-- received→committed exists for single-step definers (redefined W0-04).
-- Identity/audit columns (partner, programme, kind, creator, file meta,
-- created_at) are frozen after insert.

CREATE FUNCTION public.trg_import_run_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- INSERT: only staged runs may be created — terminal/failed statuses are
  -- definer-written outcomes reached by UPDATE.
  IF TG_OP = 'INSERT' THEN
    IF NEW.status NOT IN ('received','previewed') THEN
      RAISE EXCEPTION 'an import run cannot be inserted directly in status "%"', NEW.status;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE — the ONE write a run always accepts is its own FK's ON DELETE
  -- SET NULL (a deleted programme detaches the run; the audit record itself
  -- is untouched). Anything else falls through to the lifecycle rules.
  IF NEW.programme_id IS NULL
     AND OLD.programme_id IS NOT NULL
     AND (NEW.id, NEW.partner_id, NEW.kind, NEW.file_ref, NEW.status,
          NEW.preview, NEW.created_by, NEW.created_at, NEW.file_name,
          NEW.file_hash, NEW.committed_by, NEW.committed_at)
         IS NOT DISTINCT FROM
         (OLD.id, OLD.partner_id, OLD.kind, OLD.file_ref, OLD.status,
          OLD.preview, OLD.created_by, OLD.created_at, OLD.file_name,
          OLD.file_hash, OLD.committed_by, OLD.committed_at) THEN
    RETURN NEW;
  END IF;
  IF OLD.status IN ('committed','abandoned') THEN
    RAISE EXCEPTION 'a % import run is immutable — re-import creates a new run', OLD.status;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ( (OLD.status = 'received'
                AND NEW.status IN ('previewed','committed','abandoned','failed'))
          OR (OLD.status = 'previewed'
                AND NEW.status IN ('previewed','committed','abandoned','failed'))
          OR (OLD.status = 'failed' AND NEW.status = 'abandoned') ) THEN
      RAISE EXCEPTION 'invalid import run transition % → %', OLD.status, NEW.status;
    END IF;
  END IF;
  IF NEW.status = 'committed'
     AND (NEW.committed_by IS NULL OR NEW.committed_at IS NULL) THEN
    RAISE EXCEPTION 'committing an import run requires committed_by and committed_at';
  END IF;
  IF NEW.partner_id   IS DISTINCT FROM OLD.partner_id
     OR NEW.programme_id IS DISTINCT FROM OLD.programme_id
     OR NEW.kind         IS DISTINCT FROM OLD.kind
     OR NEW.created_by   IS DISTINCT FROM OLD.created_by
     OR NEW.created_at   IS DISTINCT FROM OLD.created_at
     OR NEW.file_ref     IS DISTINCT FROM OLD.file_ref
     OR NEW.file_name    IS DISTINCT FROM OLD.file_name
     OR NEW.file_hash    IS DISTINCT FROM OLD.file_hash THEN
    RAISE EXCEPTION 'import run partner, programme, kind, creator and file identity are immutable';
  END IF;
  RETURN NEW;
END $$;

-- no DELETE trigger: app roles hold no DELETE grant (W0-03 grants give
-- authenticated SELECT/INSERT/UPDATE only); service cleanup stays possible.
CREATE TRIGGER import_run_guard
BEFORE INSERT OR UPDATE ON public.import_runs
FOR EACH ROW EXECUTE FUNCTION public.trg_import_run_guard();

-- import_rows: frozen under terminal runs; rows may only be added to a live
-- run (received|previewed). Unconditional — definer commit writes rows while
-- the run is still 'previewed', then flips the run.
CREATE FUNCTION public.trg_import_row_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;  -- no DELETE grant for app roles; service cleanup allowed
  SELECT status INTO v_status FROM public.import_runs
   WHERE id = NEW.import_run_id;
  IF v_status IN ('committed','abandoned') THEN
    RAISE EXCEPTION 'rows of a % import run are immutable', v_status;
  END IF;
  IF TG_OP = 'INSERT' AND v_status NOT IN ('received','previewed') THEN
    RAISE EXCEPTION 'import rows cannot be added to a run in status "%"', v_status;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER import_row_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.import_rows
FOR EACH ROW EXECUTE FUNCTION public.trg_import_row_guard();


-- ---------- 5. shared guards + row parser ----------

-- Write gate for run-level RPCs: partner write roles on the target programme
-- (decision 5 — identical to W0-04's import gate). Programme-less runs fall
-- back to the partner-scope variant.
CREATE FUNCTION public.import_assert_write(p_run public.import_runs) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_run.programme_id IS NOT NULL THEN
    IF NOT public.has_programme_role(p_run.programme_id,
          ARRAY['partner_admin','partner_consultant']) THEN
      RAISE EXCEPTION 'imports require a partner_admin or partner_consultant role on this programme';
    END IF;
  ELSIF NOT public.has_partner_role(p_run.partner_id,
          ARRAY['partner_admin','partner_consultant']) THEN
    RAISE EXCEPTION 'imports require a partner_admin or partner_consultant role on this partner';
  END IF;
END $$;

-- Read gate for import_run_detail: any programme read role, or partner read.
CREATE FUNCTION public.import_assert_read(p_run public.import_runs) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_run.programme_id IS NOT NULL THEN
    IF NOT public.has_programme_role(p_run.programme_id,
          ARRAY['partner_admin','partner_consultant','read_only',
                'client_admin','executive','accountable_officer','programme_lead']) THEN
      RAISE EXCEPTION 'Access denied to import run';
    END IF;
  ELSIF NOT public.has_partner_role(p_run.partner_id,
          ARRAY['partner_admin','partner_consultant','read_only']) THEN
    RAISE EXCEPTION 'Access denied to import run';
  END IF;
END $$;

-- Server-side row parser for the §13.1 'findings' (register items) route.
-- raw is whatever the uploader sent; canonical keys + a small alias set are
-- accepted. Returns {ok:true, parsed:{...}} or {ok:false, reason}.
CREATE FUNCTION public.import_parse_finding_row(p_raw jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ref     text;
  v_finding text;
  v_prio    text;
  v_window  text;
  v_week_s  text;
  v_week    int;
  v_lead_s  text;
  v_lead    uuid;
BEGIN
  IF p_raw IS NULL OR jsonb_typeof(p_raw) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'row is not a jsonb object');
  END IF;
  v_ref := NULLIF(btrim(COALESCE(p_raw->>'ref', p_raw->>'reference', p_raw->>'Ref', '')), '');
  IF v_ref IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing required field "ref"');
  END IF;
  IF char_length(v_ref) > 64 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ref is longer than 64 characters');
  END IF;
  v_finding := NULLIF(btrim(COALESCE(p_raw->>'finding', p_raw->>'description', '')), '');
  IF v_finding IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing required field "finding"');
  END IF;
  v_prio := initcap(btrim(COALESCE(p_raw->>'priority', 'Medium')));
  IF v_prio NOT IN ('High','Medium','Low') THEN
    RETURN jsonb_build_object('ok', false, 'reason',
      'priority must be High, Medium or Low (got "' || COALESCE(p_raw->>'priority', '') || '")');
  END IF;
  v_window := NULLIF(btrim(COALESCE(p_raw->>'assessment_window', p_raw->>'window', '')), '');
  v_week_s := btrim(COALESCE(p_raw->>'planned_close_week', p_raw->>'week', ''));
  IF v_week_s <> '' THEN
    BEGIN
      v_week := v_week_s::int;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'reason',
        'planned_close_week must be a whole number (got "' || v_week_s || '")');
    END;
    IF v_week < 1 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'planned_close_week must be >= 1');
    END IF;
  END IF;
  v_lead_s := NULLIF(btrim(COALESCE(p_raw->>'lead', p_raw->>'lead_email', p_raw->>'owner', '')), '');
  IF v_lead_s IS NOT NULL THEN
    SELECT u.id INTO v_lead FROM public.users u WHERE lower(u.email) = lower(v_lead_s);
    IF v_lead IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason',
        'lead "' || v_lead_s || '" is not a known user email');
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'parsed', jsonb_build_object(
      'ref', v_ref, 'finding', v_finding, 'priority', v_prio,
      'assessment_window', v_window, 'planned_close_week', v_week,
      'lead', v_lead));
END $$;
COMMENT ON FUNCTION public.import_parse_finding_row(jsonb) IS
  'W3-01: validates + normalises one findings-register import row. Server is '
  'the authority — the UI''s header mapping is only a convenience. Rejects '
  'carry the FR-IMP-05 reason.';


-- ---------- 6. import_begin — upload stage ----------

CREATE FUNCTION public.import_begin(
    p_programme_id uuid, p_kind text, p_file_name text,
    p_file_hash text DEFAULT NULL, p_rows jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog    public.programmes;
  v_partner uuid;
  v_run     uuid;
  v_rows    int;
  v_prior   int := 0;
  v_bad     int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', p_programme_id; END IF;
  IF v_prog.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to programme';
  END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant']) THEN
    RAISE EXCEPTION 'importing requires a partner_admin or partner_consultant role on this programme';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'cannot import into a closed programme';
  END IF;
  IF p_kind IS DISTINCT FROM 'findings' THEN
    RAISE EXCEPTION 'import kind "%" is not wired yet — the framework currently '
      'supports "findings" (register items); documents, tracker and '
      'assessment_workbook routes land next', p_kind;
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array'
     OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows must be a non-empty jsonb array of row objects';
  END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN
    RAISE EXCEPTION 'one import run is capped at 5000 rows (got %)', jsonb_array_length(p_rows);
  END IF;
  SELECT count(*) INTO v_bad
    FROM jsonb_array_elements(p_rows) e(elem)
   WHERE jsonb_typeof(e.elem) <> 'object';
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% row(s) are not jsonb objects — send parsed rows, not raw file text', v_bad;
  END IF;

  SELECT c.practice_id INTO v_partner FROM public.client_orgs c
   WHERE c.id = v_prog.client_org_id;

  INSERT INTO public.import_runs
      (partner_id, programme_id, kind, file_ref, file_name, file_hash,
       status, preview, created_by)
  VALUES (v_partner, p_programme_id, p_kind,
          CASE WHEN p_file_name IS NULL THEN NULL ELSE 'upload:' || p_file_name END,
          p_file_name, p_file_hash, 'received', '{}'::jsonb, auth.uid())
  RETURNING id INTO v_run;

  INSERT INTO public.import_rows (import_run_id, row_no, raw, status)
  SELECT v_run, e.ord::int, e.elem, 'pending'
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS e(elem, ord);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF p_file_hash IS NOT NULL THEN
    SELECT count(*) INTO v_prior FROM public.import_runs r
     WHERE r.programme_id = p_programme_id AND r.kind = p_kind
       AND r.file_hash = p_file_hash AND r.id <> v_run;
  END IF;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_partner, 'import.run_created',
          jsonb_build_object('import_run_id', v_run, 'programme_id', p_programme_id,
                             'kind', p_kind, 'file_name', p_file_name,
                             'rows', v_rows));

  RETURN jsonb_build_object('import_run_id', v_run, 'rows', v_rows,
                            'prior_runs_same_file', v_prior);
END $$;
COMMENT ON FUNCTION public.import_begin(uuid, text, text, text, jsonb) IS
  'W3-01 FR-IMP-05 upload stage: parks the parsed file rows on a ''received'' '
  'run (rows ''pending''). Nothing is applied yet — preview then commit. '
  'partner_id is derived from the programme''s client, never the payload. '
  'Partner write roles only; closed programmes rejected; kind ''findings'' '
  'wired, others raise a clear not-wired error.';


-- ---------- 7. import_preview — dry-run diff (FR-IMP-05) ----------

CREATE FUNCTION public.import_preview(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_run     public.import_runs;
  v_row     record;
  v_parse   jsonb;
  v_parsed  jsonb;
  v_ok      int := 0;
  v_rej     int := 0;
  v_create  int := 0;
  v_exists  int := 0;
  v_seen    jsonb := '{}'::jsonb;        -- ref → first row_no (in-file dedupe)
  v_rejects jsonb := '[]'::jsonb;
  v_diff    jsonb := '[]'::jsonb;
  v_ex      record;
  v_outcome text;
  v_differs boolean;
  v_preview jsonb;
  v_prog_status text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_run FROM public.import_runs WHERE id = p_run_id FOR UPDATE;
  IF v_run IS NULL THEN RAISE EXCEPTION 'import run % not found', p_run_id; END IF;
  PERFORM public.import_assert_write(v_run);

  -- re-previewing a committed run returns the stored record (idempotent read)
  IF v_run.status = 'committed' THEN
    RETURN v_run.preview || jsonb_build_object('already_committed', true);
  END IF;
  IF v_run.status NOT IN ('received','previewed') THEN
    RAISE EXCEPTION 'a % import run cannot be previewed', v_run.status;
  END IF;
  IF v_run.programme_id IS NULL THEN
    RAISE EXCEPTION 'import run % has no programme target — only programme file imports can be previewed', p_run_id;
  END IF;
  IF v_run.kind <> 'findings' THEN
    RAISE EXCEPTION 'import kind "%" is not wired for preview yet', v_run.kind;
  END IF;
  SELECT status INTO v_prog_status FROM public.programmes WHERE id = v_run.programme_id;
  IF v_prog_status = 'closed' THEN
    RAISE EXCEPTION 'cannot import into a closed programme';
  END IF;

  FOR v_row IN SELECT * FROM public.import_rows
                WHERE import_run_id = p_run_id ORDER BY row_no FOR UPDATE LOOP
    -- every preview re-derives from the ORIGINAL uploaded row (idempotent re-preview)
    v_parse := public.import_parse_finding_row(v_row.raw - '_parsed' - '_outcome'
                                               - '_exists_id' - '_differs' - '_applied');
    IF NOT (v_parse->>'ok')::boolean THEN
      v_rej := v_rej + 1;
      UPDATE public.import_rows
         SET status = 'rejected', reject_reason = v_parse->>'reason',
             raw = v_row.raw - '_parsed' - '_outcome' - '_exists_id' - '_differs' - '_applied'
       WHERE id = v_row.id;
      IF jsonb_array_length(v_rejects) < 200 THEN
        v_rejects := v_rejects || jsonb_build_object(
            'row_no', v_row.row_no, 'ref', COALESCE(v_row.raw->>'ref', ''),
            'reason', v_parse->>'reason');
      END IF;
      CONTINUE;
    END IF;

    v_parsed := v_parse->'parsed';
    IF v_seen ? (v_parsed->>'ref') THEN
      v_rej := v_rej + 1;
      UPDATE public.import_rows
         SET status = 'rejected',
             reject_reason = 'duplicate ref "' || (v_parsed->>'ref')
                             || '" in file — first seen at row ' || (v_seen->>(v_parsed->>'ref')),
             raw = v_row.raw - '_parsed' - '_outcome' - '_exists_id' - '_differs' - '_applied'
       WHERE id = v_row.id;
      IF jsonb_array_length(v_rejects) < 200 THEN
        v_rejects := v_rejects || jsonb_build_object(
            'row_no', v_row.row_no, 'ref', v_parsed->>'ref',
            'reason', 'duplicate ref — first seen at row ' || (v_seen->>(v_parsed->>'ref')));
      END IF;
      CONTINUE;
    END IF;
    v_seen := v_seen || jsonb_build_object(v_parsed->>'ref', v_row.row_no);

    -- dry-run diff: would this row create a finding or land on an existing ref?
    SELECT id, finding, priority INTO v_ex
      FROM public.register_items
     WHERE programme_id = v_run.programme_id AND ref = (v_parsed->>'ref');
    IF FOUND THEN
      v_outcome := 'exists';
      v_exists  := v_exists + 1;
      v_differs := (v_ex.finding IS DISTINCT FROM v_parsed->>'finding')
                OR (v_ex.priority IS DISTINCT FROM v_parsed->>'priority');
    ELSE
      v_outcome := 'create';
      v_create  := v_create + 1;
      v_differs := NULL;
    END IF;
    v_ok := v_ok + 1;

    UPDATE public.import_rows
       SET status = 'ok', reject_reason = NULL,
           raw = (v_row.raw - '_parsed' - '_outcome' - '_exists_id' - '_differs' - '_applied')
                 || jsonb_build_object('_parsed', v_parsed,
                                       '_outcome', v_outcome,
                                       '_exists_id', v_ex.id,
                                       '_differs', v_differs)
     WHERE id = v_row.id;
    IF jsonb_array_length(v_diff) < 500 THEN
      v_diff := v_diff || jsonb_build_object(
          'row_no', v_row.row_no, 'ref', v_parsed->>'ref',
          'outcome', v_outcome, 'differs', v_differs);
    END IF;
  END LOOP;

  v_preview := jsonb_build_object(
      'kind', v_run.kind, 'programme_id', v_run.programme_id,
      'file_name', v_run.file_name,
      'rows', v_ok + v_rej, 'ok', v_ok, 'rejected', v_rej,
      'will_create', v_create, 'already_exists', v_exists,
      'rejects', v_rejects,
      'rejects_truncated', v_rej > 200,
      'diff', v_diff,
      'diff_truncated', v_ok > 500);

  UPDATE public.import_runs SET status = 'previewed', preview = v_preview
   WHERE id = p_run_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_run.partner_id, 'import.previewed',
          jsonb_build_object('import_run_id', p_run_id,
                             'programme_id', v_run.programme_id,
                             'kind', v_run.kind, 'rows', v_ok + v_rej,
                             'ok', v_ok, 'rejected', v_rej,
                             'will_create', v_create, 'already_exists', v_exists));

  RETURN v_preview;
END $$;
COMMENT ON FUNCTION public.import_preview(uuid) IS
  'W3-01 FR-IMP-05 dry run: validates every row server-side (per-row ok|'
  'rejected + reason, in-file dup detection), diffs refs against the '
  'programme register (create | exists | differs flag), writes the preview '
  'payload + row statuses, flips the run to ''previewed''. Nothing reaches '
  'register_items here. Idempotent: re-preview re-derives from the raw rows.';


-- ---------- 8. import_commit — apply with provenance ----------

CREATE FUNCTION public.import_commit(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_run      public.import_runs;
  v_row      record;
  v_parsed   jsonb;
  v_item     uuid;
  v_created  int := 0;
  v_existing int := 0;
  v_skipped  int := 0;
  v_rejected int := 0;
  v_outcome  text;
  v_prog     public.programmes;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_run FROM public.import_runs WHERE id = p_run_id FOR UPDATE;
  IF v_run IS NULL THEN RAISE EXCEPTION 'import run % not found', p_run_id; END IF;
  PERFORM public.import_assert_write(v_run);

  -- idempotent re-commit: a committed run is its own record — no changes
  IF v_run.status = 'committed' THEN
    RETURN v_run.preview || jsonb_build_object('already_committed', true);
  END IF;
  IF v_run.status <> 'previewed' THEN
    RAISE EXCEPTION 'import run must be previewed before commit (current: %)', v_run.status;
  END IF;
  IF v_run.kind <> 'findings' THEN
    RAISE EXCEPTION 'import kind "%" is not wired for commit yet', v_run.kind;
  END IF;
  -- serialise concurrent imports/register writes on the ref dedupe check
  SELECT * INTO v_prog FROM public.programmes WHERE id = v_run.programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme % not found', v_run.programme_id; END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'cannot import into a closed programme';
  END IF;

  SELECT count(*) INTO v_rejected FROM public.import_rows
   WHERE import_run_id = p_run_id AND status = 'rejected';

  FOR v_row IN SELECT * FROM public.import_rows
                WHERE import_run_id = p_run_id AND status = 'ok'
                ORDER BY row_no FOR UPDATE LOOP
    v_parsed := v_row.raw->'_parsed';
    IF v_parsed IS NULL THEN
      -- ok row without a parse payload (written by a non-RPC path): mark it
      -- skipped rather than inventing values.
      UPDATE public.import_rows
         SET status = 'skipped', reject_reason = 'no parsed payload — re-run preview',
             raw = v_row.raw || '{"_outcome":"skipped"}'::jsonb
       WHERE id = v_row.id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- commit-time dedupe (the register may have changed since preview)
    SELECT id INTO v_item FROM public.register_items
     WHERE programme_id = v_run.programme_id AND ref = (v_parsed->>'ref');
    IF v_item IS NOT NULL THEN
      v_outcome  := 'already_imported';
      v_existing := v_existing + 1;
    ELSE
      INSERT INTO public.register_items
          (programme_id, ref, finding, priority, assessment_window,
           planned_close_week, lead, import_run_id)
      VALUES (v_run.programme_id, v_parsed->>'ref', v_parsed->>'finding',
              v_parsed->>'priority', v_parsed->>'assessment_window',
              (v_parsed->>'planned_close_week')::int,
              (v_parsed->>'lead')::uuid, p_run_id)
      RETURNING id INTO v_item;
      v_outcome := 'created';
      v_created := v_created + 1;
    END IF;

    UPDATE public.import_rows
       SET mapped_entity = 'register_items:' || v_item,
           raw = v_row.raw || jsonb_build_object('_outcome', v_outcome, '_applied', v_item)
     WHERE id = v_row.id;
  END LOOP;

  IF v_created > 0 THEN
    PERFORM public.recompute_programme_progress(v_run.programme_id);  -- planned_close_date/days_overdue CALCs
  END IF;

  UPDATE public.import_runs
     SET status = 'committed', committed_by = auth.uid(), committed_at = now(),
         preview = preview || jsonb_build_object(
             'created', v_created, 'already_imported', v_existing,
             'skipped', v_skipped, 'committed', true)
   WHERE id = p_run_id;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_run.partner_id, 'import.committed',
          jsonb_build_object('import_run_id', p_run_id,
                             'programme_id', v_run.programme_id,
                             'kind', v_run.kind, 'file_name', v_run.file_name,
                             'created', v_created, 'already_imported', v_existing,
                             'skipped', v_skipped, 'rejected', v_rejected));

  RETURN jsonb_build_object('import_run_id', p_run_id,
                            'created', v_created, 'already_imported', v_existing,
                            'skipped', v_skipped, 'rejected', v_rejected);
END $$;
COMMENT ON FUNCTION public.import_commit(uuid) IS
  'W3-01 FR-IMP-05 commit: applies every ''ok'' row as a register_items '
  'insert with import_run_id provenance + mapped_entity lineage, deduping on '
  '(programme_id, ref) at commit time — re-runs create nothing. Run → '
  'committed (committed_by/at stamped), audit import.committed. Re-commit '
  'of a committed run is a no-op. Partner write roles; preview first; closed '
  'programmes rejected.';


-- ---------- 9. import_abandon ----------

CREATE FUNCTION public.import_abandon(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_run public.import_runs;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_run FROM public.import_runs WHERE id = p_run_id FOR UPDATE;
  IF v_run IS NULL THEN RAISE EXCEPTION 'import run % not found', p_run_id; END IF;
  PERFORM public.import_assert_write(v_run);
  IF v_run.status = 'committed' THEN
    RAISE EXCEPTION 'a committed import run cannot be abandoned';
  END IF;
  IF v_run.status = 'abandoned' THEN
    RETURN jsonb_build_object('import_run_id', p_run_id, 'status', 'abandoned');
  END IF;
  UPDATE public.import_runs SET status = 'abandoned' WHERE id = p_run_id;
  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_run.partner_id, 'import.abandoned',
          jsonb_build_object('import_run_id', p_run_id,
                             'programme_id', v_run.programme_id,
                             'kind', v_run.kind, 'from_status', v_run.status));
  RETURN jsonb_build_object('import_run_id', p_run_id, 'status', 'abandoned');
END $$;
COMMENT ON FUNCTION public.import_abandon(uuid) IS
  'W3-01: discard a received/previewed/failed run (the UI''s cancel path). '
  'Committed runs can never be abandoned — the run is the audit record.';


-- ---------- 10. import_run_detail — guarded read ----------

CREATE FUNCTION public.import_run_detail(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_run  public.import_runs;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT * INTO v_run FROM public.import_runs WHERE id = p_run_id;
  IF v_run IS NULL THEN RAISE EXCEPTION 'import run % not found', p_run_id; END IF;
  PERFORM public.import_assert_read(v_run);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'row_no', ir.row_no, 'status', ir.status,
             'reject_reason', ir.reject_reason,
             'mapped_entity', ir.mapped_entity, 'raw', ir.raw)
           ORDER BY ir.row_no), '[]'::jsonb)
    INTO v_rows FROM public.import_rows ir WHERE ir.import_run_id = p_run_id;
  RETURN jsonb_build_object(
      'run', jsonb_build_object(
          'id', v_run.id, 'partner_id', v_run.partner_id,
          'programme_id', v_run.programme_id, 'kind', v_run.kind,
          'file_name', v_run.file_name, 'file_hash', v_run.file_hash,
          'file_ref', v_run.file_ref, 'status', v_run.status,
          'preview', v_run.preview, 'created_by', v_run.created_by,
          'created_at', v_run.created_at,
          'committed_by', v_run.committed_by, 'committed_at', v_run.committed_at),
      'rows', v_rows);
END $$;
COMMENT ON FUNCTION public.import_run_detail(uuid) IS
  'W3-01 guarded read: the run + every row for callers holding a programme '
  'read role (or partner read on programme-less runs). The UI uses it for '
  'run history; partner-scope callers can also SELECT the tables directly.';


-- ---------- 11. W0-04 redefined for the versioning model ----------
-- import_assessment_findings (20261106000011) inserted its run 'committed'
-- then UPDATEd the preview in place — illegal under the unconditional guard.
-- Identical function, one ordering change: the run lands 'received', rows
-- are written, then ONE update flips it 'committed' with the preview +
-- commit stamps. Signature, results and audit action are unchanged;
-- e2e_tracks_bridge keeps passing verbatim.

CREATE OR REPLACE FUNCTION public.import_assessment_findings(
    p_programme_id uuid, p_assessment_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prog     public.programmes;
  v_sess     public.assessment_sessions;
  v_practice uuid;
  v_run      uuid;
  v_row_no   int := 0;
  v_created  int := 0;
  v_existing int := 0;
  v_gap      record;
  v_item     uuid;
  v_ref      text;
  v_outcome  text;
  v_window   text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- lock the programme: concurrent imports of the same session serialise here
  SELECT * INTO v_prog FROM public.programmes WHERE id = p_programme_id FOR UPDATE;
  IF v_prog IS NULL THEN RAISE EXCEPTION 'programme not found'; END IF;
  SELECT * INTO v_sess FROM public.assessment_sessions WHERE id = p_assessment_session_id;
  IF v_sess IS NULL THEN RAISE EXCEPTION 'assessment session not found'; END IF;

  -- in-body guards
  IF v_prog.client_org_id NOT IN (SELECT public.allowed_client_orgs())
     OR v_sess.client_org_id NOT IN (SELECT public.allowed_client_orgs()) THEN
    RAISE EXCEPTION 'Access denied to programme or assessment';
  END IF;
  IF NOT public.has_programme_role(p_programme_id,
        ARRAY['partner_admin','partner_consultant']) THEN
    RAISE EXCEPTION 'importing findings requires a partner_admin or partner_consultant role on this programme';
  END IF;
  IF v_sess.client_org_id <> v_prog.client_org_id THEN
    RAISE EXCEPTION 'cross-client import denied: the assessment belongs to a different client';
  END IF;
  IF v_prog.status = 'closed' THEN
    RAISE EXCEPTION 'findings cannot be imported into a closed programme';
  END IF;

  SELECT practice_id INTO v_practice FROM public.client_orgs WHERE id = v_prog.client_org_id;
  v_window := NULLIF(concat_ws(' · ', v_sess.title, v_sess.audit_date::text), '');

  -- W3-01: run starts 'received' (staged), becomes 'committed' in ONE update
  -- after the rows are written — the unconditional versioning guard's flow.
  INSERT INTO public.import_runs
      (partner_id, programme_id, kind, file_ref, status, preview, created_by)
  VALUES (v_practice, p_programme_id, 'findings',
          'assessment_sessions:' || p_assessment_session_id,
          'received', '{}'::jsonb, auth.uid())
  RETURNING id INTO v_run;

  FOR v_gap IN
    SELECT q.uid, q.question, q.risk, q.section_id, q.section_name, q.question_number,
           q.regulatory_ref, r.response, r.findings
      FROM public.assessment_responses r
      JOIN public.assessment_questions q ON q.id = r.question_id
     WHERE r.session_id = p_assessment_session_id
       AND r.response IN ('non_compliant','partial')
     ORDER BY q.section_id, q.question_number, q.uid
  LOOP
    v_row_no := v_row_no + 1;
    SELECT id INTO v_item FROM public.register_items
     WHERE programme_id = p_programme_id
       AND source_assessment_session_id = p_assessment_session_id
       AND source_question_ref = v_gap.uid;

    IF v_item IS NOT NULL THEN
      v_outcome  := 'already_imported';
      v_existing := v_existing + 1;
    ELSE
      v_ref := 'ASM-' || v_gap.uid;
      IF EXISTS (SELECT 1 FROM public.register_items
                  WHERE programme_id = p_programme_id AND ref = v_ref) THEN
        v_ref := v_ref || '-' || left(p_assessment_session_id::text, 8);
      END IF;
      INSERT INTO public.register_items
          (programme_id, ref, finding, priority, assessment_window,
           source_assessment_session_id, source_question_ref)
      VALUES (p_programme_id, v_ref,
              v_gap.question
                || CASE WHEN NULLIF(btrim(v_gap.findings), '') IS NOT NULL
                        THEN E'\n— ' || btrim(v_gap.findings) ELSE '' END,
              CASE v_gap.risk WHEN 'Critical' THEN 'High' WHEN 'High' THEN 'High'
                              WHEN 'Medium' THEN 'Medium' ELSE 'Low' END,
              v_window, p_assessment_session_id, v_gap.uid)
      RETURNING id INTO v_item;
      v_outcome := 'created';
      v_created := v_created + 1;
    END IF;

    INSERT INTO public.import_rows (import_run_id, row_no, raw, status, mapped_entity)
    VALUES (v_run, v_row_no,
            jsonb_build_object('assessment_session_id', p_assessment_session_id,
                               'question_ref', v_gap.uid,
                               'section', v_gap.section_name,
                               'question_number', v_gap.question_number,
                               'question', v_gap.question,
                               'regulatory_ref', v_gap.regulatory_ref,
                               'risk', v_gap.risk,
                               'response', v_gap.response,
                               'findings', v_gap.findings,
                               'approval_status', v_sess.approval_status,
                               'outcome', v_outcome),
            'ok', 'register_items:' || v_item);
  END LOOP;

  UPDATE public.import_runs
     SET status = 'committed', committed_by = auth.uid(), committed_at = now(),
         preview = jsonb_build_object(
           'source', 'assessment_session',
           'assessment_session_id', p_assessment_session_id,
           'programme_id', p_programme_id,
           'framework', v_sess.framework,
           'approval_status', v_sess.approval_status,
           'rows', v_row_no, 'created', v_created,
           'already_imported', v_existing, 'rejected', 0)
   WHERE id = v_run;

  INSERT INTO public.audit_log (user_id, practice_id, action, detail)
  VALUES (auth.uid(), v_practice, 'register.findings_imported',
          jsonb_build_object('programme_id', p_programme_id,
                             'assessment_session_id', p_assessment_session_id,
                             'import_run_id', v_run,
                             'created', v_created, 'already_imported', v_existing));

  RETURN jsonb_build_object('import_run_id', v_run, 'rows', v_row_no,
                            'created', v_created, 'already_imported', v_existing);
END $$;
COMMENT ON FUNCTION public.import_assessment_findings(uuid, uuid) IS
  'W0-04 §13 findings route (W3-01 redefinition — same contract): Stage 1 '
  'gaps (non_compliant/partial responses) become register_items with '
  'provenance. Idempotent per (programme, session, question). Writes the '
  'import_runs/import_rows trail via the received→committed lifecycle the '
  'versioning guard requires. Partner write roles only.';


-- ---------- 12. RLS: programme-scope readers see their own runs ----------
-- W0-03's partner-scope policies stand; these add the T2 programme view so
-- client/programme-scoped callers (e.g. the TESTFIX consultant) can read
-- runs and rows for programmes they can see.

CREATE POLICY import_runs_programme_read ON public.import_runs
FOR SELECT TO authenticated
USING (programme_id IS NOT NULL
       AND programme_id IN (SELECT public.allowed_programmes()));

CREATE POLICY import_rows_programme_read ON public.import_rows
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.import_runs r
   WHERE r.id = import_rows.import_run_id
     AND r.programme_id IS NOT NULL
     AND r.programme_id IN (SELECT public.allowed_programmes())));


-- ---------- 12. grants (W0-00 convention: lock the surface) ----------
REVOKE EXECUTE ON FUNCTION
  public.trg_import_run_guard(),
  public.trg_import_row_guard(),
  public.import_assert_write(public.import_runs),
  public.import_assert_read(public.import_runs),
  public.import_parse_finding_row(jsonb),
  public.import_begin(uuid, text, text, text, jsonb),
  public.import_preview(uuid),
  public.import_commit(uuid),
  public.import_abandon(uuid),
  public.import_run_detail(uuid)
FROM anon, public, authenticated;

GRANT EXECUTE ON FUNCTION
  public.import_begin(uuid, text, text, text, jsonb),
  public.import_preview(uuid),
  public.import_commit(uuid),
  public.import_abandon(uuid),
  public.import_run_detail(uuid)
TO authenticated;

COMMIT;
