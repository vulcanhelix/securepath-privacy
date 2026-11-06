-- ============================================================================
-- W0-03 — TEMPLATE ENGINE: programme_templates + programme_template_versions,
-- requirement_mappings, import_runs/import_rows
-- (GitHub #12 · spec SP-SPC-PLT-001 §5, §6.1, §13.1 · plan BUILD_PLAN_R1 §3 W0-03)
-- ============================================================================
--
-- Applies AFTER 00002 (references public.jurisdiction_packs.code) and 00003
-- (adds the deferred FKs on programmes.template_version_id and
-- maintenance_task_templates.template_version_id). Filename ordering puts
-- this file behind both once the wave branches land on main.
--
-- Every programme is created from a PUBLISHED template version (§5). The
-- template carries the whole §5.1 content pack in one versioned jsonb
-- document; SecurePath authors content in a draft, and the platform publishes
-- it as a numbered version (FR-TPL-01). Published and retired versions are
-- immutable records (FR-TPL-02 — publishing a new version never changes a
-- running programme).
--
-- --------------------- POLICY / WRITE MODEL (W0-00 catalogue) --------------
--   programme_templates / programme_template_versions / requirement_mappings:
--     shared library — READ by any authenticated caller holding ANY active
--     assignment (spec: published content is shared; partner-private variants
--     additionally scoped to their partner). WRITES REVOKED from
--     authenticated — content changes go through predicate-guarded SECURITY
--     DEFINER RPCs only (publish/retire here; authoring I/O lands W3-05).
--   import_runs / import_rows: partner-scope (T1-variant on practices) —
--     partner_admin/partner_consultant write, read_only reads. No DELETE:
--     an import run is the audit record of a file load (FR-IMP-05).
--
-- DECISIONS (spec ambiguities resolved here — flagged for review):
--
-- 1. `framework` is FREE TEXT, not an FK to the legacy public.frameworks
--    registry. The legacy registry belongs to the old privacy/cyber track
--    spine with different granularity (§5.2 ships 'POPIA and PAIA' as ONE
--    template; the registry has 'popia' + 'paia' keys). R1 values per §5.2:
--    'popia_paia', 'uk_gdpr_dpa2018', 'iso27001', 'iso27701',
--    'cyber_essentials', 'cyber_essentials_za'.
--
-- 2. programme_templates.partner_id — NULL = the shared SecurePath library;
--    set = a partner-private template variant (FR-TPL-05, editor lands
--    W3-05). Column added now so variants need no ALTER later; RLS scopes
--    non-NULL rows to that partner.
--
-- 3. STATUS LIFECYCLE: draft → published → retired, plus draft → retired
--    (discard a never-published draft — 'retired' is the only terminal
--    state and a discarded draft should not read as published history).
--    published/retired rows reject every UPDATE except the
--    published→retired transition, and every DELETE. Drafts are freely
--    editable/deletable.
--
-- 4. content jsonb — the whole §5.1 shape in one document; publish (and any
--    draft→published write) requires ALL eleven component keys to be
--    present (they may be empty arrays/objects — absence is the error):
--    phases, workstreams, activity_library, findings_map, document_set,
--    kpis, maintenance_set, quarterly_annual_cycles, registers,
--    report_structure, role_labels.
--
-- 5. requirement_mappings rows are OWNED by the template version that
--    asserts them (mappings ship as versioned content, editable while the
--    version is a draft). requirement_ref_a/b are TEXT refs into framework
--    content (e.g. 'popia:s.19(1)', 'iso27701:6.3.1') — not row FKs, because
--    refs point at requirements inside versioned content / legislation.
--    mapping_type vocabulary: equivalent | partial | related (spec names no
--    vocabulary; 'partial' covers the common many-to-few overlaps).
--
-- 6. import_runs.kind vocabulary: findings (FR-IMP-01), assessment_workbook
--    (FR-IMP-02), tracker (FR-IMP-04), template (FR-TPL-06), portal_api
--    (FR-IMP-03 forward). import_rows.mapped_entity is a free-form text ref
--    ('<table>:<uuid>' by convention) — the concrete mapping engine lands
--    in W3-01 and needs no schema change to use it.
--
-- 7. Both deferred template_version FKs from 00003 are added here —
--    programmes.template_version_id AND maintenance_task_templates
--    .template_version_id (the mission names the former; the latter is the
--    same deferred pattern in the same file).

BEGIN;

-- ---------- 1. tables ----------

-- ---- programme_templates — §6.1 "Template" (framework, edition,
-- jurisdiction). Has versions. Shared library + FR-TPL-05 variants.
CREATE TABLE public.programme_templates (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework    text NOT NULL,            -- free text, e.g. 'popia_paia' (decision 1)
    edition      text,                     -- content-authored, e.g. '2022' / 'v3.1'
    jurisdiction text REFERENCES public.jurisdiction_packs(code),
                 -- NULL = any jurisdiction (ISO templates — FR-ONB-03 always offered)
    name         text NOT NULL,
    source_refs  jsonb NOT NULL DEFAULT '[]'::jsonb,
                 -- citations; §5.5: ISO clause/control numbers + own wording only
    partner_id   uuid REFERENCES public.practices(id) ON DELETE CASCADE,
                 -- NULL = SecurePath shared library (decision 2)
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  public.programme_templates IS
  'Spec §6.1 Template + §5: one row per framework template (six in R1). '
  'jurisdiction NULL = any-jurisdiction (FR-ONB-03). partner_id NULL = shared '
  'library; set = partner-private variant (FR-TPL-05). Writes via definer '
  'RPCs only.';
COMMENT ON COLUMN public.programme_templates.source_refs IS
  'Source references for the content (legislation sections, standard clause '
  'numbers). §5.5 copyright rule: cite numbers, never reproduce standards text.';
CREATE INDEX programme_templates_framework_idx ON public.programme_templates (framework);
CREATE INDEX programme_templates_partner_idx   ON public.programme_templates (partner_id)
  WHERE partner_id IS NOT NULL;

-- ---- programme_template_versions — §6.1 "Template version". Numbered,
-- draft|published|retired, published_by/at, release notes, §5.1 content.
CREATE TABLE public.programme_template_versions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id   uuid NOT NULL REFERENCES public.programme_templates(id) ON DELETE CASCADE,
    number        int  NOT NULL CHECK (number > 0),
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','published','retired')),
    published_by  uuid REFERENCES public.users(id),
    published_at  timestamptz,
    release_notes text,                    -- partner-visible "what changed" (FR-TPL-03)
    content       jsonb NOT NULL DEFAULT '{}'::jsonb
                  CHECK (jsonb_typeof(content) = 'object'),   -- §5.1 shape (decision 4)
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_id, number),
    CHECK (status <> 'published' OR (published_by IS NOT NULL AND published_at IS NOT NULL))
);
COMMENT ON TABLE  public.programme_template_versions IS
  'Spec §6.1 Template version — numbered, status draft|published|retired. '
  'Published and retired versions are immutable records (FR-TPL-02); the '
  'trg_template_version_guard trigger enforces transitions on every write '
  'path. Writes via definer RPCs only.';
COMMENT ON COLUMN public.programme_template_versions.content IS
  '§5.1 content pack, one jsonb document. Required keys at publish time: '
  'phases, workstreams, activity_library, findings_map, document_set, kpis, '
  'maintenance_set, quarterly_annual_cycles, registers, report_structure, '
  'role_labels. FR-TPL-08: every legal period lives in jurisdiction_packs.'
  'deadline_params or inside this content as a named parameter — never in code.';
CREATE INDEX ptv_template_idx ON public.programme_template_versions (template_id);

-- ---- requirement_mappings — §6.1 "Requirement mapping". Links requirements
-- across frameworks so evidence accepted in one programme can be OFFERED for
-- a mapped requirement in another for the same client (FR-TPL-07).
CREATE TABLE public.requirement_mappings (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_version_id uuid NOT NULL REFERENCES public.programme_template_versions(id)
                        ON DELETE CASCADE,
    requirement_ref_a   text NOT NULL,
    requirement_ref_b   text NOT NULL,
    mapping_type        text NOT NULL
                        CHECK (mapping_type IN ('equivalent','partial','related')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_version_id, requirement_ref_a, requirement_ref_b)
);
COMMENT ON TABLE public.requirement_mappings IS
  'Spec §6.1 Requirement mapping — links a requirement in framework A to one '
  'in framework B (FR-TPL-07 cross-framework evidence offers; acceptance is '
  'still per-programme). Rows are owned by the template version that asserts '
  'them and follow its draft/published lifecycle.';
COMMENT ON COLUMN public.requirement_mappings.requirement_ref_a IS
  'Free-form requirement reference into versioned content or legislation '
  '(e.g. ''popia:s.19(1)'', ''iso27701:6.3.1'') — text by decision 5.';
CREATE INDEX requirement_mappings_version_idx ON public.requirement_mappings (template_version_id);
CREATE INDEX requirement_mappings_refs_idx
  ON public.requirement_mappings (requirement_ref_a, requirement_ref_b);

-- ---- import_runs — §13.1 FR-IMP-05. One run per file load; preview jsonb
-- holds the pre-write preview the user confirms before anything is applied.
CREATE TABLE public.import_runs (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
    kind       text NOT NULL
               CHECK (kind IN ('findings','assessment_workbook','tracker',
                               'template','portal_api')),
    file_ref   text,                          -- storage object ref for the source file
    status     text NOT NULL DEFAULT 'received'
               CHECK (status IN ('received','previewed','committed',
                                 'abandoned','failed')),
    preview    jsonb NOT NULL DEFAULT '{}'::jsonb,   -- FR-IMP-05 preview payload + reject summary
    created_by uuid DEFAULT auth.uid() REFERENCES public.users(id),  -- write-protected: no INSERT grant
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.import_runs IS
  'Spec §13.1 import run — one row per file load (findings, assessment '
  'workbook, tracker, template; portal_api reserved for FR-IMP-03). '
  'FR-IMP-05: preview + per-row rejections are shown before anything is '
  'written; status received→previewed→committed|abandoned|failed. '
  'Append-mostly: no DELETE.';
CREATE INDEX import_runs_partner_idx ON public.import_runs (partner_id, created_at DESC);

-- ---- import_rows — per-row parse outcome for the run.
CREATE TABLE public.import_rows (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    import_run_id uuid NOT NULL REFERENCES public.import_runs(id) ON DELETE CASCADE,
    row_no        int  NOT NULL,
    raw           jsonb NOT NULL DEFAULT '{}'::jsonb,  -- the row as parsed from the file
    status        text NOT NULL CHECK (status IN ('ok','rejected')),
    reject_reason text,
    mapped_entity text,                 -- '<table>:<uuid>' ref once applied (decision 6)
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (import_run_id, row_no),
    CHECK (status = 'ok' OR reject_reason IS NOT NULL)   -- FR-IMP-05: rejections always carry a reason
);
COMMENT ON TABLE public.import_rows IS
  'Spec §13.1 FR-IMP-05 — one row per source-file row: raw parse, ok|rejected '
  'with a mandatory reason, and the entity it mapped to when committed.';
CREATE INDEX import_rows_run_idx ON public.import_rows (import_run_id, row_no);


-- ---------- 2. deferred FKs from 00003 (template_version_id) ----------

ALTER TABLE public.programmes
  ADD CONSTRAINT programmes_template_version_fkey
  FOREIGN KEY (template_version_id) REFERENCES public.programme_template_versions(id);

ALTER TABLE public.maintenance_task_templates
  ADD CONSTRAINT mtt_template_version_fkey
  FOREIGN KEY (template_version_id) REFERENCES public.programme_template_versions(id);


-- ---------- 3. visibility predicate + lifecycle triggers + publish RPC ----------

-- Read gate used by the three content tables: version visible when the
-- template is readable (shared library or own partner variant) and the
-- version is published/retired — drafts are platform-content-only.
CREATE FUNCTION public.template_version_visible(p_version uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.programme_template_versions v
    JOIN public.programme_templates t ON t.id = v.template_id
    WHERE v.id = p_version
      AND ( v.status IN ('published','retired')
         OR public.is_platform_role(ARRAY['platform_admin','content_author']) )
      AND ( t.partner_id IS NULL
         OR public.has_partner_role(t.partner_id,
                    ARRAY['partner_admin','partner_consultant','read_only'])
         OR public.is_platform_role(ARRAY['platform_admin','content_author','support']) ))
$$;
COMMENT ON FUNCTION public.template_version_visible(uuid) IS
  'W0-03 predicate: is this template version visible to the caller? '
  'Published/retired = shared library read; drafts = platform content roles '
  'only; partner-private variants read inside their partner.';

-- §5.1 content shape check — called by the publish path AND by the guard
-- trigger, so no write path can publish a malformed pack.
CREATE FUNCTION public.assert_template_content(p_content jsonb) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_missing text[];
BEGIN
  IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'template version content must be a jsonb object holding the §5.1 components';
  END IF;
  SELECT array_agg(t.k) INTO v_missing
  FROM (VALUES ('phases'),('workstreams'),('activity_library'),('findings_map'),
               ('document_set'),('kpis'),('maintenance_set'),
               ('quarterly_annual_cycles'),('registers'),('report_structure'),
               ('role_labels')) AS t(k)
  WHERE NOT (p_content ? t.k);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'template version content is missing §5.1 components: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;
COMMENT ON FUNCTION public.assert_template_content(jsonb) IS
  'W0-03 §5.1 publish gate: the content object must carry all eleven '
  'component keys (empty is fine, missing is not). Callable by authoring '
  'code for pre-flight validation.';

-- Lifecycle guard — runs on EVERY write path (direct SQL, definer RPC,
-- service role alike) because publish immutability is a hard rule.
CREATE FUNCTION public.trg_template_version_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION
        'only draft template versions may be deleted — published and retired versions are immutable records (FR-TPL-02)';
    END IF;
    RETURN OLD;
  END IF;
  -- UPDATE
  IF OLD.status = 'retired' THEN
    RAISE EXCEPTION 'a retired template version cannot change';
  END IF;
  IF OLD.status = 'published' THEN
    -- the only legal write on a published row is the status → 'retired'
    -- transition; every other column is frozen (FR-TPL-02).
    IF NEW.status <> 'retired'
       OR NEW.template_id   IS DISTINCT FROM OLD.template_id
       OR NEW.number        IS DISTINCT FROM OLD.number
       OR NEW.content       IS DISTINCT FROM OLD.content
       OR NEW.release_notes IS DISTINCT FROM OLD.release_notes
       OR NEW.published_by  IS DISTINCT FROM OLD.published_by
       OR NEW.published_at  IS DISTINCT FROM OLD.published_at THEN
      RAISE EXCEPTION
        'a published template version is immutable — only retiring it is allowed (FR-TPL-02)';
    END IF;
    RETURN NEW;
  END IF;
  -- OLD.status = 'draft': free edits; a draft→published write must carry the
  -- publish record and a complete §5.1 content pack.
  IF NEW.status = 'published' THEN
    IF NEW.published_by IS NULL OR NEW.published_at IS NULL THEN
      RAISE EXCEPTION 'publishing a version requires published_by and published_at';
    END IF;
    PERFORM public.assert_template_content(NEW.content);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER template_version_guard
BEFORE UPDATE OR DELETE ON public.programme_template_versions
FOR EACH ROW EXECUTE FUNCTION public.trg_template_version_guard();

-- publish_template_version — FR-TPL-01. The only publish path: definer RPC
-- guarded by the platform content predicate (definer bypasses RLS, so the
-- check lives in the body per the W0-00 hard rule).
CREATE FUNCTION public.publish_template_version(p_version uuid)
RETURNS public.programme_template_versions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.programme_template_versions%ROWTYPE;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','content_author']) THEN
    RAISE EXCEPTION
      'only a platform content author or platform admin may publish template versions (FR-TPL-01)';
  END IF;
  SELECT * INTO v_row FROM public.programme_template_versions
   WHERE id = p_version FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template version % not found', p_version;
  END IF;
  IF v_row.status <> 'draft' THEN
    RAISE EXCEPTION 'only a draft version can be published (current status: %)', v_row.status;
  END IF;
  PERFORM public.assert_template_content(v_row.content);
  UPDATE public.programme_template_versions
     SET status = 'published', published_by = auth.uid(), published_at = now()
   WHERE id = p_version
   RETURNING * INTO v_row;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.publish_template_version(uuid) IS
  'W0-03 FR-TPL-01: platform_admin/content_author publishes a numbered draft '
  'version. Freezes content (immutable afterwards) and stamps '
  'published_by/published_at.';

-- retire_template_version — completes the lifecycle: published → retired.
-- Needed because authenticated holds no UPDATE grant on versions; without it
-- a published version could never be retired.
CREATE FUNCTION public.retire_template_version(p_version uuid)
RETURNS public.programme_template_versions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.programme_template_versions%ROWTYPE;
BEGIN
  IF NOT public.is_platform_role(ARRAY['platform_admin','content_author']) THEN
    RAISE EXCEPTION
      'only a platform content author or platform admin may retire template versions';
  END IF;
  SELECT * INTO v_row FROM public.programme_template_versions
   WHERE id = p_version FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template version % not found', p_version;
  END IF;
  IF v_row.status <> 'published' THEN
    RAISE EXCEPTION 'only a published version can be retired (current status: %)', v_row.status;
  END IF;
  UPDATE public.programme_template_versions
     SET status = 'retired'
   WHERE id = p_version
   RETURNING * INTO v_row;
  RETURN v_row;
END $$;
COMMENT ON FUNCTION public.retire_template_version(uuid) IS
  'W0-03: published → retired transition. Retired versions stay readable — '
  'running programmes still reference them (FR-TPL-02).';


-- ---------- 4. RLS ----------
-- Content tables: SELECT for anyone holding ANY active assignment
-- ("read by any authenticated role that can read client-scope — published
-- content is shared"), narrowed per the template_version_visible predicate.
-- No write policies: REVOKE INSERT/UPDATE/DELETE — definer RPCs only.

ALTER TABLE public.programme_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programme_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY programme_templates_read ON public.programme_templates
FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()))
  AND ( partner_id IS NULL
     OR public.has_partner_role(partner_id,
                ARRAY['partner_admin','partner_consultant','read_only'])
     OR public.is_platform_role(ARRAY['platform_admin','content_author','support']) )
);
REVOKE ALL ON public.programme_templates FROM anon, authenticated;
GRANT SELECT ON public.programme_templates TO authenticated;

ALTER TABLE public.programme_template_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programme_template_versions FORCE ROW LEVEL SECURITY;
CREATE POLICY programme_template_versions_read ON public.programme_template_versions
FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()))
  AND public.template_version_visible(id)
);
REVOKE ALL ON public.programme_template_versions FROM anon, authenticated;
GRANT SELECT ON public.programme_template_versions TO authenticated;

ALTER TABLE public.requirement_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requirement_mappings FORCE ROW LEVEL SECURITY;
CREATE POLICY requirement_mappings_read ON public.requirement_mappings
FOR SELECT TO authenticated
USING (
  EXISTS (SELECT 1 FROM public.active_assignments(auth.uid()))
  AND public.template_version_visible(template_version_id)
);
REVOKE ALL ON public.requirement_mappings FROM anon, authenticated;
GRANT SELECT ON public.requirement_mappings TO authenticated;

-- import_runs / import_rows: partner-scope (T1-variant on practices).
ALTER TABLE public.import_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.import_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY import_runs_read ON public.import_runs FOR SELECT TO authenticated
  USING (public.has_partner_role(partner_id,
           ARRAY['partner_admin','partner_consultant','read_only']));
CREATE POLICY import_runs_insert ON public.import_runs FOR INSERT TO authenticated
  WITH CHECK (public.has_partner_role(partner_id,
                ARRAY['partner_admin','partner_consultant']));
CREATE POLICY import_runs_update ON public.import_runs FOR UPDATE TO authenticated
  USING (public.has_partner_role(partner_id,
           ARRAY['partner_admin','partner_consultant']))
  WITH CHECK (public.has_partner_role(partner_id,
                ARRAY['partner_admin','partner_consultant']));
REVOKE ALL ON public.import_runs FROM anon, authenticated;
GRANT SELECT ON public.import_runs TO authenticated;
GRANT INSERT (partner_id, kind, file_ref, status, preview) ON public.import_runs TO authenticated;
GRANT UPDATE (status, preview) ON public.import_runs TO authenticated;

ALTER TABLE public.import_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.import_rows FORCE ROW LEVEL SECURITY;
CREATE POLICY import_rows_read ON public.import_rows FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.import_runs r
                 WHERE r.id = import_rows.import_run_id
                   AND public.has_partner_role(r.partner_id,
                         ARRAY['partner_admin','partner_consultant','read_only'])));
CREATE POLICY import_rows_insert ON public.import_rows FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.import_runs r
                      WHERE r.id = import_rows.import_run_id
                        AND public.has_partner_role(r.partner_id,
                              ARRAY['partner_admin','partner_consultant'])));
CREATE POLICY import_rows_update ON public.import_rows FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.import_runs r
                 WHERE r.id = import_rows.import_run_id
                   AND public.has_partner_role(r.partner_id,
                         ARRAY['partner_admin','partner_consultant'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.import_runs r
                      WHERE r.id = import_rows.import_run_id
                        AND public.has_partner_role(r.partner_id,
                              ARRAY['partner_admin','partner_consultant'])));
REVOKE ALL ON public.import_rows FROM anon, authenticated;
GRANT SELECT ON public.import_rows TO authenticated;
GRANT INSERT (import_run_id, row_no, raw, status, reject_reason, mapped_entity)
  ON public.import_rows TO authenticated;
GRANT UPDATE (status, reject_reason, mapped_entity) ON public.import_rows TO authenticated;

-- lock function execution surface (W0-00 convention)
REVOKE EXECUTE ON FUNCTION
  public.template_version_visible(uuid),
  public.assert_template_content(jsonb),
  public.trg_template_version_guard(),
  public.publish_template_version(uuid),
  public.retire_template_version(uuid)
FROM anon, public, authenticated;
GRANT EXECUTE ON FUNCTION
  public.template_version_visible(uuid),
  public.assert_template_content(jsonb),
  public.publish_template_version(uuid),
  public.retire_template_version(uuid)
TO authenticated;

COMMIT;
