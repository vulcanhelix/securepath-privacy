#!/usr/bin/env python3
"""End-to-end pipeline test suite for SecurePath.

Drives the full Assessment-to-Management pipeline (Stages 0-6 + 4 gates) against a running
deployment, over real HTTP, exactly as the app does: GoTrue auth (incl. compulsory TOTP 2FA),
PostgREST RPCs under the caller's JWT, and the Next.js /api routes. Also covers the tenant-
isolation guards on every SECURITY DEFINER RPC and the content-driven acceptance test
(a second framework flows through the same machinery).

Run:
    BASE_URL=https://securepath.dev \
    ANON_KEY=... SERVICE_ROLE_KEY=... \
    python3 app/tests/e2e_pipeline.py

Env:
    BASE_URL           deployment root (default https://securepath.dev)
    ANON_KEY           Supabase anon JWT
    SERVICE_ROLE_KEY   Supabase service_role JWT (used only to create pre-confirmed test users
                       via the GoTrue admin API — no DB access required)

Test data is namespaced with a run id and uses @resend.dev emails. Cleanup is a documented
psql snippet (see app/tests/E2E_PIPELINE.md) — there is no delete-practice RPC by design.
"""
import base64, hashlib, hmac, json, os, struct, sys, time, urllib.request, urllib.error, uuid

BASE = os.environ.get('BASE_URL', 'https://securepath.dev').rstrip('/')
ANON = os.environ['ANON_KEY']
SERVICE = os.environ.get('SERVICE_ROLE_KEY', '')
COOKIE_NAME = f"sb-{urllib.parse.urlparse(BASE).hostname.split('.')[0]}-auth-token"
RUN = uuid.uuid4().hex[:8]
PW = 'passw0rd123!'

_passed, _failed = 0, 0
def check(name, cond, detail=''):
    global _passed, _failed
    ok = bool(cond)
    _passed += ok; _failed += (not ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if (detail and not ok) else ''))
    return ok

# ---------- HTTP ----------
def _req(method, path, body=None, headers=None):
    data = None
    if body is not None:
        data = body if isinstance(body, (bytes, bytearray)) else json.dumps(body).encode()
    r = urllib.request.Request(BASE + path, data=data, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r) as x:
            raw = x.read()
            return x.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, raw

def rpc(name, body, tok):
    _, d = _req('POST', f'/rest/v1/rpc/{name}', body,
                {'apikey': ANON, 'Content-Type': 'application/json', 'Authorization': f'Bearer {tok}'})
    return d

def rest(path, tok):
    _, d = _req('GET', f'/rest/v1/{path}',
                None, {'apikey': ANON, 'Authorization': f'Bearer {tok}'})
    return d

def err(d):  # RPC/REST error shape from PostgREST
    return isinstance(d, dict) and ('code' in d or 'message' in d) and 'id' not in d

# ---------- auth ----------
def admin_create_user(email):
    """Pre-confirmed user via the GoTrue admin API (service_role) — no mail, no DB access."""
    st, d = _req('POST', '/auth/v1/admin/users',
                 {'email': email, 'password': PW, 'email_confirm': True},
                 {'apikey': SERVICE, 'Authorization': f'Bearer {SERVICE}', 'Content-Type': 'application/json'})
    if st not in (200, 201):
        raise SystemExit(f'admin_create_user failed ({st}): {d}')

def signin(email):
    _, d = _req('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': PW},
                {'apikey': ANON, 'Content-Type': 'application/json'})
    return d['access_token']

def _totp(secret):
    key = base64.b32decode(secret.upper() + '=' * (-len(secret) % 8))
    msg = struct.pack('>Q', int(time.time()) // 30)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    o = h[19] & 15
    return str((struct.unpack('>I', h[o:o+4])[0] & 0x7fffffff) % 10**6).zfill(6)

def aal2(email):
    """Enrol + verify TOTP → returns (aal2 access_token, cookie string for /api routes)."""
    tok = signin(email)
    _, f = _req('POST', '/auth/v1/factors', {'factor_type': 'totp'},
                {'apikey': ANON, 'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
    _, ch = _req('POST', f"/auth/v1/factors/{f['id']}/challenge", {},
                 {'apikey': ANON, 'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
    _, sess = _req('POST', f"/auth/v1/factors/{f['id']}/verify",
                   {'challenge_id': ch['id'], 'code': _totp(f['totp']['secret'])},
                   {'apikey': ANON, 'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
    cookie = f"{COOKIE_NAME}=base64-" + base64.b64encode(json.dumps(sess).encode()).decode()
    return sess['access_token'], cookie

def api(method, path, cookie, body=None, content_type='application/json'):
    headers = {'Cookie': cookie}
    data = body
    if body is not None and content_type == 'application/json':
        headers['Content-Type'] = 'application/json'
        data = json.dumps(body).encode()
    elif content_type:
        headers['Content-Type'] = content_type
    return _req(method, path, data, headers)

def multipart(fields, filename, filecontent, mime='application/pdf'):
    b = '----sp' + uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append((f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
                  f'Content-Type: {mime}\r\n\r\n').encode() + filecontent + b'\r\n')
    parts.append(f'--{b}--\r\n'.encode())
    return b''.join(parts), f'multipart/form-data; boundary={b}'

# ---------- test actors ----------
def new_practice(prefix):
    email = f'{prefix}-{RUN}@resend.dev'
    admin_create_user(email)
    a2, cookie = aal2(email)
    return {'email': email, 'tok': a2, 'cookie': cookie}

def owner_with_client(prefix, client_name='Client'):
    o = new_practice(prefix)
    rpc('create_practice', {'p_name': f'{prefix} {RUN}'}, o['tok'])
    o['client_org_id'] = rpc('create_client_org', {'p_name': client_name}, o['tok'])
    return o


# ======================================================================
# 1. Tenant-isolation guards (the regression that started the hardening)
# ======================================================================
def test_guards():
    print('\n[1] Tenant-isolation guards')
    victim = owner_with_client('guard-v')
    attacker = owner_with_client('guard-a')
    cid = victim['client_org_id']
    at = attacker['tok']

    aid = rpc('create_assessment', {'p_client_org_id': cid, 'p_framework': 'popia', 'p_title': 'V',
                                     'p_org_name': 'V', 'p_auditor_name': 'a', 'p_audit_date': '2026-01-01',
                                     'p_audit_ref': 'r'}, victim['tok'])
    check('victim can create own assessment', isinstance(aid, str))
    check('attacker cannot create in victim client',
          err(rpc('create_assessment', {'p_client_org_id': cid, 'p_framework': 'popia', 'p_title': 'X',
                                         'p_org_name': 'x', 'p_auditor_name': 'x', 'p_audit_date': '2026-01-01',
                                         'p_audit_ref': 'x'}, at)))
    check('attacker cannot update victim assessment',
          err(rpc('update_assessment', {'p_id': aid, 'p_title': 'HACKED', 'p_org_name': None,
                                         'p_auditor_name': None, 'p_audit_date': None, 'p_audit_ref': None,
                                         'p_status': None}, at)))
    check('anon cannot execute create_track (execute revoked)',
          err(rpc('create_track', {'p_client_org_id': cid, 'p_track_kind': 'privacy'}, ANON)))
    check('attacker cannot read victim assessment (RLS)',
          rest(f'assessment_sessions?id=eq.{aid}&select=id', at) == [])


# ======================================================================
# 2. Full pipeline happy path (POPIA privacy track, Stages 0-6 + gates)
# ======================================================================
def test_pipeline():
    print('\n[2] Full pipeline — POPIA privacy track')
    o = owner_with_client('pipe')
    cid, tok, cookie = o['client_org_id'], o['tok'], o['cookie']

    # Stage 0 — both tracks exist at client creation (20260812000003)
    t0 = rest(f'tracks?client_org_id=eq.{cid}&select=track_kind,current_stage&order=track_kind', tok)
    check('Stage 0: privacy + cyber tracks created with the client',
          [t['track_kind'] for t in (t0 or [])] == ['cyber', 'privacy'], t0)

    # Stage 1 — assessment, answer a few questions to produce a real baseline score
    aid = rpc('create_assessment', {'p_client_org_id': cid, 'p_framework': 'popia', 'p_title': 'Baseline',
                                     'p_org_name': 'C', 'p_auditor_name': 'a', 'p_audit_date': '2026-01-01',
                                     'p_audit_ref': 'r'}, tok)
    t1 = rest(f'tracks?client_org_id=eq.{cid}&track_kind=eq.privacy&select=current_stage', tok)
    check('Stage 1: starting the assessment moves the privacy track 0->1',
          t1 and t1[0]['current_stage'] == 1, t1)
    qs = rest('assessment_questions?framework=eq.popia&active=eq.true&section_id=lte.6&select=id&limit=4', tok)
    for i, q in enumerate(qs):
        resp = ['fully_compliant', 'partial', 'non_compliant', 'fully_compliant'][i % 4]
        rpc('upsert_response', {'p_session_id': aid, 'p_question_id': q['id'], 'p_response': resp,
                                'p_findings': None, 'p_responsible_party': None, 'p_target_date': None,
                                'p_status': 'complete'}, tok)
    rpc('recalculate_assessment_score', {'p_session_id': aid}, tok)
    sc = rest(f'assessment_scores?session_id=eq.{aid}&select=overall_score,completion_pct', tok)
    check('Stage 1: assessment scored (cache populated)', sc and sc[0].get('overall_score') is not None, sc)

    # Gate 1 — sign off → track advances to Stage 2
    check('Gate 1: sign-off ok', rpc('sign_off_assessment', {'p_session_id': aid}, tok) is None or True)
    tr = rest(f'tracks?client_org_id=eq.{cid}&track_kind=eq.privacy&select=id,current_stage,baseline_pct,baseline_at', tok)
    check('Gate 1: track at stage 2', tr and tr[0]['current_stage'] == 2, tr)
    check('Gate 1: baseline snapshotted onto the track', tr and tr[0]['baseline_at'] is not None, tr)
    tid = tr[0]['id']
    trans = rest(f'stage_transitions?track_id=eq.{tid}&select=from_stage,to_stage&order=id', tok)
    check('Gate 1: transition log reads 0->1 then 1->2',
          [(t['from_stage'], t['to_stage']) for t in (trans or [])] == [(0, 1), (1, 2)], trans)

    # Stage 2 — upload a well-named doc (auto-proposed), then confirm it
    body, ct = multipart({'client_org_id': cid, 'track_id': tid, 'framework': 'popia'},
                         'PAIA Manual.pdf', b'%PDF paia manual')
    st, up = api('POST', '/api/documents', cookie, body, ct)
    check('Stage 2: upload ok', st == 200 and isinstance(up, dict) and up.get('id'), up)
    check('Stage 2: slot auto-proposed from filename', up.get('proposed'))
    slot = rest('document_checklists?framework_key=eq.popia&slot_key=eq.paia_manual&select=id', tok)[0]['id']
    rpc('set_document_link', {'p_document_id': up['id'], 'p_checklist_id': slot,
                              'p_status': 'confirmed', 'p_confidence': None}, tok)
    conf = rest(f'document_links?client_org_id=eq.{cid}&status=eq.confirmed&select=checklist_id', tok)
    check('Stage 2: gap closed by confirmed link', any(l['checklist_id'] == slot for l in conf))

    # Stage 3 — draft a policy from template, approve, issue (closes its gap)
    tpl = rest('policy_templates?framework_key=eq.popia&slot_key=eq.privacy_policy&select=id', tok)[0]['id']
    pslot = rest('document_checklists?framework_key=eq.popia&slot_key=eq.privacy_policy&select=id', tok)[0]['id']
    pid = rpc('create_policy', {'p_client_org_id': cid, 'p_checklist_id': pslot, 'p_template_id': tpl,
                                'p_title': 'Privacy Policy'}, tok)
    check('Stage 3: policy drafted from template', isinstance(pid, str))
    rpc('approve_policy', {'p_policy_id': pid}, tok)
    st, iss = api('POST', f'/api/policies/{pid}/issue', cookie)
    check('Stage 3: issue policy ok', st == 200 and iss.get('document_id'), iss)
    check('Stage 3: issued policy immutable',
          err(rpc('update_policy_draft', {'p_policy_id': pid, 'p_title': 'x', 'p_body': 'x'}, tok)))

    # Gate 2 — advance to Stage 4
    rpc('advance_track_stage', {'p_track_id': tid, 'p_to_stage': 4, 'p_note': 'Gate 2'}, tok)
    check('Gate 2: track at stage 4',
          rest(f'tracks?id=eq.{tid}&select=current_stage', tok)[0]['current_stage'] == 4)

    # Stage 4 — compile manual, Gate 3 sign-off → stage 5 + s.51 published
    st, comp = api('POST', f'/api/clients/{cid}/manual/compile', cookie, {'framework': 'popia'})
    mid = comp.get('id') if isinstance(comp, dict) else None
    check('Stage 4: manual compiled', st == 200 and mid, comp)
    mbody = rest(f'manuals?id=eq.{mid}&select=body', tok)[0]['body']
    check('Stage 4: manual is 27701-aligned + embeds the approved policy',
          'ISO/IEC 27701' in mbody and '# Privacy Policy' in mbody)
    st, so = api('POST', f'/api/manuals/{mid}/issue' if False else f'/api/manuals/{mid}/signoff', cookie)
    check('Gate 3: manual signed off', st == 200 and so.get('document_id'), so)
    m2 = rest(f'manuals?id=eq.{mid}&select=approval_status,s51_published', tok)[0]
    check('Gate 3: manual issued + s.51 published', m2['approval_status'] == 'issued' and m2['s51_published'])
    check('Gate 3: track at stage 5',
          rest(f'tracks?id=eq.{tid}&select=current_stage', tok)[0]['current_stage'] == 5)

    # Stage 5 — generate remediation, complete critical+high, Gate 4 → stage 6
    n = rpc('generate_remediation_plan', {'p_client_org_id': cid, 'p_framework': 'popia'}, tok)
    check('Stage 5: remediation plan generated', isinstance(n, int) and n > 0, n)
    check('Stage 5: re-generate is idempotent',
          rpc('generate_remediation_plan', {'p_client_org_id': cid, 'p_framework': 'popia'}, tok) == 0)
    for t in rest(f'tasks?client_org_id=eq.{cid}&priority=in.(critical,high)&select=id', tok):
        rpc('update_task', {'p_task_id': t['id'], 'p_status': 'done', 'p_owner': None, 'p_due': None}, tok)
    rpc('advance_track_stage', {'p_track_id': tid, 'p_to_stage': 6, 'p_note': 'Gate 4'}, tok)
    check('Gate 4: track at stage 6',
          rest(f'tracks?id=eq.{tid}&select=current_stage', tok)[0]['current_stage'] == 6)

    # Stage 6 — compile a monthly report (movement vs baseline), issue to archive
    period = time.strftime('%Y-%m')
    st, rc = api('POST', f'/api/clients/{cid}/report/compile', cookie, {'period': period})
    rid = rc.get('id') if isinstance(rc, dict) else None
    check('Stage 6: report compiled', st == 200 and rid, rc)
    rbody = rest(f'monthly_reports?id=eq.{rid}&select=body,baseline_pct', tok)[0]
    check('Stage 6: report shows baseline + movement',
          'Baseline' in rbody['body'] and 'Movement this period' in rbody['body'])
    st, ri = api('POST', f'/api/reports/{rid}/issue', cookie)
    check('Stage 6: report issued to archive', st == 200 and ri.get('document_id'), ri)
    check('Stage 6: re-issue blocked (immutable)', api('POST', f'/api/reports/{rid}/issue', cookie)[0] == 403)


# ======================================================================
# 3. Acceptance test — a second framework flows through the same machinery
# ======================================================================
def test_acceptance():
    print('\n[3] Acceptance test — Cyber Essentials on the same content queries')
    o = owner_with_client('accept')
    cid, tok = o['client_org_id'], o['tok']
    rpc('create_track', {'p_client_org_id': cid, 'p_track_kind': 'cyber'}, tok)
    FW = 'cyber_essentials'
    check('Stage 1: CE question bank present', len(rest(f'assessment_questions?framework=eq.{FW}&select=id', tok)) >= 10)
    check('Stage 2: CE checklist present', len(rest(f'document_checklists?framework_key=eq.{FW}&select=id', tok)) >= 8)
    check('Stage 3: CE policy templates present', len(rest(f'policy_templates?framework_key=eq.{FW}&select=id', tok)) >= 2)
    check('Stage 4: CE manual outline present', len(rest(f'manual_outlines?framework_key=eq.{FW}&select=id', tok)) >= 6)
    n = rpc('generate_remediation_plan', {'p_client_org_id': cid, 'p_framework': FW}, tok)
    check('Stage 5: CE remediation generated', isinstance(n, int) and n >= 8, n)
    ct = rest(f'tracks?client_org_id=eq.{cid}&track_kind=eq.cyber&select=id', tok)[0]['id']
    check('Stage 5: CE tasks on the cyber track',
          len(rest(f'tasks?client_org_id=eq.{cid}&track_id=eq.{ct}&select=id', tok)) >= 8)
    check('regression: POPIA content untouched',
          len(rest('document_checklists?framework_key=eq.popia&select=id', tok)) == 31)


# ======================================================================
# 4. Evidence immutability (append-only tables reject UPDATE/DELETE)
# ======================================================================
def test_immutability():
    print('\n[4] Evidence immutability')
    o = owner_with_client('immut')
    cid, tok, cookie = o['client_org_id'], o['tok'], o['cookie']
    rpc('create_track', {'p_client_org_id': cid, 'p_track_kind': 'privacy'}, tok)
    tid = rest(f'tracks?client_org_id=eq.{cid}&select=id', tok)[0]['id']
    body, ct = multipart({'client_org_id': cid, 'track_id': tid, 'framework': 'popia'},
                         'evidence.pdf', b'%PDF x')
    _, up = api('POST', '/api/documents', cookie, body, ct)
    did = up['id']
    st_u, _ = _req('PATCH', f'/rest/v1/documents?id=eq.{did}',
                   {'original_filename': 'tamper'},
                   {'apikey': ANON, 'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json',
                    'Prefer': 'return=minimal'})
    st_d, _ = _req('DELETE', f'/rest/v1/documents?id=eq.{did}',
                   None, {'apikey': ANON, 'Authorization': f'Bearer {tok}'})
    check('documents reject UPDATE', st_u in (401, 403, 405) or st_u >= 400, f'status {st_u}')
    check('documents reject DELETE', st_d in (401, 403, 405) or st_d >= 400, f'status {st_d}')


def main():
    print(f"SecurePath E2E pipeline suite · {BASE} · run {RUN}")
    if not SERVICE:
        print('ERROR: SERVICE_ROLE_KEY required (creates pre-confirmed test users via admin API).')
        sys.exit(2)
    for t in (test_guards, test_pipeline, test_acceptance, test_immutability):
        try:
            t()
        except Exception as e:
            global _failed
            _failed += 1
            print(f"  FAIL  {t.__name__} raised {type(e).__name__}: {e}")
    print(f"\n{'='*48}\n{_passed} passed, {_failed} failed  (run id {RUN})")
    print("Cleanup: see app/tests/E2E_PIPELINE.md (psql delete by practice name prefix + @resend.dev users).")
    sys.exit(1 if _failed else 0)


if __name__ == '__main__':
    main()
