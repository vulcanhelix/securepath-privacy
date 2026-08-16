#!/usr/bin/env python3
"""E2E tenant-isolation proof against the real stack: GoTrue auth -> JWT -> PostgREST -> RLS.

Creates two MSP practices with real users, then asserts every cross-tenant path fails.
Run: python3 e2e_isolation.py  (needs SUPABASE_URL, ANON_KEY, SERVICE_KEY env vars)
"""
import json, os, sys, urllib.request, urllib.error

BASE = os.environ["SUPABASE_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_KEY"]

passed = failed = 0

def check(label, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"PASS {label}")
    else:
        failed += 1
        print(f"FAIL {label} {detail}")

def req(method, path, token, body=None, key=None, prefer=None):
    url = BASE + path
    headers = {"apikey": key or ANON, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    if prefer:
        headers["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode()

def purge_test_users():
    """Make the suite rerunnable: drop any leftover @e2e.test identities and their tenant data."""
    st, body = req("GET", "/auth/v1/admin/users?per_page=200", SERVICE, key=SERVICE)
    assert st == 200, f"list users: {st} {body}"
    # deleting the auth user cascades to public.users -> memberships + consultant_assignments.
    # orphaned practices/client_orgs stay behind but are invisible to every new user, so
    # assertions are unaffected.
    for u in body.get("users", []):
        if u["email"].endswith("@e2e.test"):
            st2, b2 = req("DELETE", f"/auth/v1/admin/users/{u['id']}", SERVICE, key=SERVICE)
            assert st2 in (200, 204), f"purge {u['email']}: {st2} {b2}"

def admin_create_user(email, pw):
    st, body = req("POST", "/auth/v1/admin/users", SERVICE, {"email": email, "password": pw, "email_confirm": True}, key=SERVICE)
    assert st in (200, 201), f"create {email}: {st} {body}"
    return body["id"]

def login(email, pw):
    st, body = req("POST", "/auth/v1/token?grant_type=password", ANON, {"email": email, "password": pw})
    assert st == 200, f"login {email}: {st} {body}"
    return body["access_token"]

PW = "PocPassw0rd!x"
purge_test_users()
users = {n: admin_create_user(f"{n}@e2e.test", PW) for n in
         ["owner.alpha", "consultant.alpha", "clientadmin.alpha", "owner.beta"]}
tok = {n: login(f"{n}@e2e.test", PW) for n in users}
print("users + logins OK")

# ---- Alpha practice setup (as alpha owner, via API only) ----
st, alpha_pid = req("POST", "/rest/v1/rpc/create_practice", tok["owner.alpha"], {"p_name": "MSP Alpha"})
check("alpha owner creates practice", st == 200, f"{st} {alpha_pid}")

st, body = req("POST", "/rest/v1/client_orgs", tok["owner.alpha"],
               [{"practice_id": alpha_pid, "name": "Alpha Client 1"},
                {"practice_id": alpha_pid, "name": "Alpha Client 2"}], prefer="return=representation")
check("alpha owner creates 2 client orgs", st == 201 and len(body) == 2, f"{st} {body}")
ac1, ac2 = body[0]["id"], body[1]["id"]

st, _ = req("POST", "/rest/v1/rpc/add_member", tok["owner.alpha"],
            {"p_user_id": users["consultant.alpha"], "p_role": "practice_consultant"})
check("add consultant", st in (200, 204), st)
st, _ = req("POST", "/rest/v1/rpc/add_member", tok["owner.alpha"],
            {"p_user_id": users["clientadmin.alpha"], "p_role": "client_admin", "p_client_org_id": ac1})
check("add client admin", st in (200, 204), st)

st, _ = req("POST", "/rest/v1/consultant_assignments", tok["owner.alpha"],
            {"user_id": users["consultant.alpha"], "client_org_id": ac1})
check("assign consultant to client 1 only", st == 201, st)

st, body = req("POST", "/rest/v1/assessment_sessions", tok["owner.alpha"],
               [{"client_org_id": ac1, "title": "Alpha C1 POPIA baseline", "score_pct": 61},
                {"client_org_id": ac2, "title": "Alpha C2 POPIA baseline", "score_pct": 47}],
               prefer="return=representation")
check("alpha owner creates assessments", st == 201, f"{st} {body}")
alpha_assessment_id = body[0]["id"]

# ---- Beta practice setup ----
st, beta_pid = req("POST", "/rest/v1/rpc/create_practice", tok["owner.beta"], {"p_name": "MSP Beta"})
check("beta owner creates practice", st == 200, f"{st} {beta_pid}")
st, body = req("POST", "/rest/v1/client_orgs", tok["owner.beta"],
               {"practice_id": beta_pid, "name": "Beta Client 1"}, prefer="return=representation")
bc1 = body[0]["id"]
st, _ = req("POST", "/rest/v1/assessment_sessions", tok["owner.beta"],
            {"client_org_id": bc1, "title": "Beta C1 POPIA baseline", "score_pct": 82})
check("beta owner creates assessment", st == 201, st)

# ---- Isolation asserts ----
st, body = req("GET", "/rest/v1/assessment_sessions?select=id,title", tok["owner.beta"], None)
check("beta owner sees only own assessment", st == 200 and len(body) == 1 and "Beta" in body[0]["title"], f"{st} {body}")

st, body = req("GET", f"/rest/v1/assessment_sessions?id=eq.{alpha_assessment_id}", tok["owner.beta"], None)
check("beta owner: alpha row invisible by exact id", st == 200 and body == [], f"{st} {body}")

st, body = req("PATCH", f"/rest/v1/assessment_sessions?id=eq.{alpha_assessment_id}", tok["owner.beta"],
               {"score_pct": 0}, prefer="return=representation")
check("beta owner: cross-tenant UPDATE affects 0 rows", st in (200, 404) and (body == [] or body is None), f"{st} {body}")

st, body = req("POST", "/rest/v1/assessment_sessions", tok["owner.beta"],
               {"client_org_id": ac1, "title": "intrusion"})
check("beta owner: cross-tenant INSERT rejected", st in (401, 403), f"{st} {body}")

st, body = req("POST", "/rest/v1/client_orgs", tok["owner.beta"],
               {"practice_id": alpha_pid, "name": "sneaky org"})
check("beta owner: client org under alpha practice rejected", st in (401, 403), f"{st} {body}")

st, body = req("GET", "/rest/v1/assessment_sessions?select=id,title", tok["consultant.alpha"], None)
check("consultant sees only assigned client's assessment", st == 200 and len(body) == 1 and "C1" in body[0]["title"], f"{st} {body}")

st, body = req("GET", "/rest/v1/client_orgs?select=id", tok["consultant.alpha"], None)
check("consultant sees 1 of 2 sibling client orgs", st == 200 and len(body) == 1, f"{st} {body}")

st, body = req("GET", "/rest/v1/assessment_sessions?select=id,title", tok["clientadmin.alpha"], None)
check("client admin sees only own org", st == 200 and len(body) == 1 and "C1" in body[0]["title"], f"{st} {body}")

st, body = req("GET", "/rest/v1/practices?select=id,name", tok["clientadmin.alpha"], None)
check("client admin sees own practice only", st == 200 and len(body) == 1, f"{st} {body}")

st, _ = req("POST", "/rest/v1/rpc/add_member", tok["clientadmin.alpha"],
            {"p_user_id": users["owner.beta"], "p_role": "practice_owner"})
check("client admin cannot add members", st >= 400, st)

st, body = req("GET", "/rest/v1/assessment_sessions", "not-a-token", None)
check("garbage token rejected", st == 401, f"{st}")

st, body = req("GET", "/rest/v1/assessment_sessions", ANON, None)
check("anon sees nothing", st in (200, 401, 403) and (body == [] or st != 200), f"{st} {body}")

st, _ = req("POST", "/rest/v1/rpc/create_practice", tok["owner.alpha"], {"p_name": "Second practice"})
check("one practice per user enforced", st >= 400, st)

st, body = req("PATCH", "/rest/v1/audit_log?id=gt.0", tok["owner.alpha"], {"action": "tampered"})
check("audit log immutable via API", st in (401, 403, 404, 405), f"{st} {body}")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
