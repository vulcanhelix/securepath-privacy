#!/usr/bin/env python3
"""uat_watcher.py — UAT feedback pipeline for SecurePath.

Runs via systemd timer every ~5 min. State machine:

  new Linear ticket (UAT team)
    -> triage: headless Devin ACP run evaluates vs spec (reject only w/ citation)
    -> accept: GitHub issue labelled uat-ticket + uat-confirmed
    -> pushback: gentle Linear reply citing spec; Bruce pinged (ntfy + assign)
    -> fix: label-gated headless run implements on a worktree branch + tests
       + playwright video saved to disk
    -> awaiting_approval: video posted to ticket; 48h nudge; tester approves
    -> pr_pending -> pr: watcher pushes branch + opens PR deterministically;
       merge on green CI + review
    -> done

Sessions are LOCAL: tools/uat/acp_run.py spawns `devin acp --model <tier>`
(headless, bypass mode) inside a git worktree under tools/uat/runs/<id>/.
Triage runs use swe-2-flash-medium; fixes use swe-2-max. No cloud ACU spend.

Trivial tickets (label `uat-trivial`) skip the tester-approval gate.

State persists in /root/.local/state/uat-watcher/state.json — crash-safe.

Usage:
  uat_watcher.py --once          single poll pass (timer uses this)
  uat_watcher.py --setup         discover team/states, create intake template
  uat_watcher.py --status        print tracked tickets
"""

import json, os, re, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, '..', '..'))
RUNS_DIR = os.path.join(ROOT, 'runs')
STATE_DIR = os.path.expanduser('~/.local/state/uat-watcher')
STATE_FILE = os.path.join(STATE_DIR, 'state.json')
ACP_RUN = os.path.join(ROOT, 'acp_run.py')
GH_REPO = 'vulcanhelix/securepath-privacy'
LINEAR_GQL = 'https://api.linear.app/graphql'
NTFY_TOPIC = 'securepath-ops-d2e6906f'
NUDGE_AFTER_S = 48 * 3600
POLL_TIMEOUT_NOTE_S = 6 * 3600  # warn if a run is quiet this long
TRIAGE_MODEL = 'swe-2-max'
FIX_MODEL = 'swe-2-max'
MAX_CONCURRENT_FIX = 1

VERDICT_RX = re.compile(r'VERDICT:\s*(ACCEPT|PUSHBACK)', re.I)
PR_RX = re.compile(r'PR:\s*(https://github\.com/\S+)', re.I)
DONE_RX = re.compile(r'UAT-FIX-DONE', re.I)
APPROVAL_RX = re.compile(r'\b(yes|approved?|sorted|looks good|lgtm|correct|fixed|great|perfect|that.?s it)\b', re.I)
NEGATION_RX = re.compile(r"\b(no|not|n't|still|wrong|doesn|isn|didn|hasn|wasn|broken|unfixed)\b", re.I)


def is_approval(body):
    """Positive approval word AND no negation — 'no it isn't fixed' must not
    count as approval."""
    return bool(APPROVAL_RX.search(body)) and not NEGATION_RX.search(body)


def env(name, default=''):
    if name in os.environ:
        return os.environ[name]
    f = os.path.expanduser('~/.secrets/linear.env')
    if os.path.exists(f):
        for line in open(f):
            if line.startswith(name + '='):
                return line.split('=', 1)[1].strip()
    return default


LINEAR_KEY = env('LINEAR_API_KEY')
TEAM_KEY = env('LINEAR_TEAM_KEY', 'GRO')  # team key prefix; UAT issues carry label `uat`
UAT_LABEL = env('LINEAR_UAT_LABEL', 'uat')


def gql(query, variables=None, _tries=3):
    body = json.dumps({'query': query, 'variables': variables or {}}).encode()
    req = urllib.request.Request(LINEAR_GQL, data=body, method='POST', headers={
        'Authorization': LINEAR_KEY, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f'Linear API {e.code}: {e.read()[:300]}')
    except Exception:
        if _tries <= 1:
            raise
        time.sleep(3)
        return gql(query, variables, _tries - 1)
    if d.get('errors'):
        raise SystemExit(f'Linear GQL errors: {d["errors"][:2]}')
    return d.get('data', {})


def load_state():
    if os.path.exists(STATE_FILE):
        return json.load(open(STATE_FILE))
    return {'tickets': {}, 'teams': {}}


def save_state(st):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + '.tmp'
    json.dump(st, open(tmp, 'w'), indent=2)
    os.replace(tmp, STATE_FILE)


def sh(*args, check=True, timeout=120):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f'{" ".join(args)}\n{r.stderr[:400]}')
    return r


def acp_spawn(prompt, name, cwd, model):
    """Detach a headless Devin ACP run. Returns the run id (dir under runs/)."""
    run_id = f'{int(time.time())}-{re.sub(r"[^a-z0-9]+", "-", name.lower())[:40]}'
    rd = os.path.join(RUNS_DIR, run_id)
    os.makedirs(rd, exist_ok=True)
    with open(os.path.join(rd, 'prompt.txt'), 'w') as f:
        f.write(prompt)
    log = os.path.join(rd, 'agent.log')
    subprocess.Popen(
        ['python3', ACP_RUN, '--prompt-file', os.path.join(rd, 'prompt.txt'),
         '--cwd', cwd, '--model', model, '--log', log],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    return run_id


def run_dir(run_id):
    return os.path.join(RUNS_DIR, run_id)


def run_log(run_id):
    """Agent text + markers only — the prompt never lands in the log, so
    regexes can't match example lines the way the cloud dump could."""
    try:
        return open(os.path.join(run_dir(run_id), 'agent.log')).read()
    except OSError:
        return ''


def run_finished(run_id):
    """Process gone or ACP-RUN-END marker written."""
    log = run_log(run_id)
    if 'ACP-RUN-END' in log:
        return True
    try:
        pid = int(open(os.path.join(run_dir(run_id), 'agent.log.pid')).read().split()[-1])
        os.kill(pid, 0)
        return False
    except (OSError, ValueError):
        return True  # no pid file yet or process dead


def run_failed(run_id):
    return run_finished(run_id) and 'ACP-RUN-END' not in run_log(run_id)


def kill_run_leftovers(worktree):
    """Fix agents may leave dev servers/caddy running from their worktree —
    kill anything whose cmdline or cwd points inside it."""
    if not worktree:
        return
    try:
        for pid in os.listdir('/proc'):
            if not pid.isdigit():
                continue
            try:
                cmd = open(f'/proc/{pid}/cmdline', 'rb').read().decode(errors='replace')
                cwd = os.readlink(f'/proc/{pid}/cwd')
                if worktree in cmd or cwd.startswith(worktree):
                    os.kill(int(pid), 9)
            except (OSError, ValueError):
                continue
    except OSError:
        pass


def find_video(run_id, worktree):
    """Newest mp4 the fix run left in its run dir or the worktree."""
    cands = []
    for base in (run_dir(run_id), worktree or ''):
        if base and os.path.isdir(base):
            for dp, _, fns in os.walk(base):
                cands += [os.path.join(dp, f) for f in fns if f.endswith('.mp4')]
    return max(cands, key=os.path.getmtime) if cands else None


def make_worktree(branch, gh_num):
    """Isolated checkout for a fix run so concurrent work can't collide."""
    wt = os.path.join(RUNS_DIR, f'wt-{gh_num}')
    sh('git', '-C', REPO, 'fetch', 'origin', 'main', check=False)
    if os.path.isdir(wt):
        sh('git', '-C', REPO, 'worktree', 'remove', '--force', wt, check=False)
    sh('git', '-C', REPO, 'worktree', 'add', wt, '-b', branch, 'origin/main')
    return wt


def open_pr(tk):
    """Deterministic PR step — no agent needed: push the fix branch, gh pr create."""
    wt, branch = tk['worktree'], tk['branch']
    sh('git', '-C', wt, 'push', '-u', 'origin', branch)
    r = sh('gh', 'pr', 'create', '--repo', GH_REPO, '--head', branch,
           '--title', f"[UAT] {tk.get('gh_title', tk['id'])}",
           '--body', f"UAT fix for {tk.get('gh_url', '')} / Linear {tk['id']}.\n\n"
                     'Fix session run locally (headless Devin ACP, swe-2-max); '
                     'video evidence is on the Linear ticket.\n\n'
                     'Merge gate: green CI + review.')
    return r.stdout.strip().splitlines()[-1]


def ntfy(msg):
    try:
        urllib.request.urlopen(urllib.request.Request(
            f'https://ntfy.sh/{NTFY_TOPIC}', data=msg.encode(),
            headers={'Title': 'SecurePath UAT'}), timeout=10)
    except Exception:
        pass


def comment(issue_id, body):
    gql('mutation($i:String!,$b:String!){commentCreate(input:{issueId:$i,body:$b}){success}}',
        {'i': issue_id, 'b': body})


def set_state(issue_id, state_id):
    gql('mutation($i:String!,$s:String!){issueUpdate(id:$i,input:{stateId:$s}){success}}',
        {'i': issue_id, 's': state_id})


def team():
    d = gql('query{teams{nodes{id key name states{nodes{id name type position}}}}}')
    for t in d['teams']['nodes']:
        if t['key'] == TEAM_KEY:
            return t
    raise SystemExit(f'no Linear team with key {TEAM_KEY} — teams: '
                     + ', '.join(t["key"] for t in d["teams"]["nodes"]))


def team_state_id(t, *names):
    for n in names:
        for s in t['states']['nodes']:
            if s['name'].lower() == n:
                return s['id']
    return None


def issues(tid):
    d = gql('''query($t:ID!){issues(filter:{team:{id:{eq:$t}}},first:100){
        nodes{id identifier title description createdAt
              state{name type} labels{nodes{name}}}}}''', {'t': tid})
    return d['issues']['nodes']


def comments(issue_id):
    d = gql('''query($i:String!){issue(id:$i){comments{nodes{
        id body createdAt user{name isMe}}}}}''', {'i': issue_id})
    issue = d.get('issue') or {}
    return issue.get('comments', {}).get('nodes', [])


def linear_upload(path):
    size = os.path.getsize(path)
    name = os.path.basename(path)
    d = gql('''mutation($c:String!,$f:String!,$s:Int!){fileUpload(
        contentType:$c,filename:$f,size:$s){success uploadFile{
        uploadUrl assetUrl headers{key value}}}}''',
        {'c': 'video/mp4', 'f': name, 's': size})
    uf = (d.get('fileUpload') or {}).get('uploadFile') or {}
    url, asset = uf.get('uploadUrl'), uf.get('assetUrl')
    if not url:
        return None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=open(path, 'rb').read(), method='PUT')
            req.add_header('Content-Type', 'video/mp4')
            for h in uf.get('headers') or []:
                req.add_header(h['key'], h['value'])
            urllib.request.urlopen(req, timeout=300)
            return asset
        except Exception:
            if attempt == 2:
                raise
            time.sleep(3)


def triage_prompt(issue):
    return f"""You are the UAT triage for SecurePath. You are running headless inside the
repo checkout (vulcanhelix/securepath-privacy); the spec is
docs/spec/SP-SPC-PLT-001_v0_2.txt — read the relevant sections before deciding.
Do NOT edit any files. A UAT tester filed this ticket:

TITLE: {issue['title']}
BODY:
{issue.get('description') or '(no description)'}

Your job: decide if this is a real defect/missing behaviour. Rules:
- REJECT (pushback) ONLY if the spec or the AT-suite expectations clearly say the
  current behaviour is correct — cite the section. Otherwise ACCEPT.
- If the report is unclear, still ACCEPT but note what's ambiguous.
- The tester is non-technical: bias toward accepting.
- If structured fields (expected vs actual, page, screenshot) are missing, note
  what you'd want — do not reject for that alone.

End your reply with EXACTLY this structure and nothing after TECH:
VERDICT: ACCEPT    or    VERDICT: PUSHBACK
EXPLANATION: <2-4 sentence plain-language explanation for the tester>
TECH: <one-line technical summary for the fix session, only on ACCEPT>"""


def fix_prompt(gh_url, lin_ref, tech, branch, worktree, video_dir):
    return f"""Fix UAT issue {gh_url} in vulcanhelix/securepath-privacy.

You are running headless in a git worktree at {worktree} on branch {branch}
(already created off origin/main). Context: this came from UAT testing
({lin_ref}). Technical summary: {tech}

Rules:
- Work only inside {worktree}. Do NOT merge to main. Do NOT push.
- Implement the fix, run the relevant SQL/browser tests (see .github/workflows/e2e.yml
  and AGENTS.md). Add or update a test if the bug class lacks coverage.
- Record a ~30s playwright video proving the fix works on the live flow
  (web/ has playwright). Save the mp4 into {video_dir}/.
- Commit your changes on {branch} with a clear message. Leave the tree clean.
- Do NOT open a PR — that step is handled automatically after human approval.
- When done, end your reply with a line containing exactly: UAT-FIX-DONE
- If after honest investigation the report does not reproduce or turns out not
  to be a defect, do NOT fake a fix: end with UAT-NO-REPRO plus a short plain
  explanation of what you checked and why it isn't a bug.
"""


def spawn_or_fail(st, tk, ident, iid, prompt, name, cwd, model):
    """Spawn an ACP run; retry once on dead runs, then mark the ticket failed."""
    rid = acp_spawn(prompt, name, cwd, model)
    tk.update(session=rid, since=time.time())
    return rid


def respawn_or_fail(st, tk, ident, iid, what):
    """A run finished without its expected marker or died. Retry once, then fail."""
    tries = tk.get('spawn_tries', 0)
    if tries < 1:
        tk['spawn_tries'] = tries + 1
        return True
    tk.update(phase='failed', since=time.time())
    ntfy(f'UAT {ident}: {what} run failed twice — needs a human')
    comment(iid, 'The automated pass on this hit an internal error twice — '
                 'Bruce has been pinged and will pick it up manually.')
    return False


def tick(st):
    if not LINEAR_KEY:
        print('LINEAR_API_KEY not set — fill ~/.secrets/linear.env')
        return
    t = team()
    st['teams'][TEAM_KEY] = {'id': t['id']}
    inprog = team_state_id(t, 'in progress')
    now = time.time()
    fixing_count = sum(1 for x in st['tickets'].values() if x.get('phase') == 'fixing')

    for iss in issues(t['id']):
        if not any(l['name'].lower() == UAT_LABEL for l in iss['labels']['nodes']):
            continue
        iid, ident = iss['id'], iss['identifier']
        tk = st['tickets'].get(iid)
        if not tk:
            # ignore tickets already terminal before we first saw them
            if iss['state']['type'] in ('completed', 'canceled'):
                continue
            rid = acp_spawn(triage_prompt(iss), f'triage-{ident}', REPO, TRIAGE_MODEL)
            st['tickets'][iid] = {'id': ident, 'phase': 'triaging',
                                  'session': rid, 'since': now, 'spawn_tries': 0}
            comment(iid, 'Thanks — looking at this now. I\'ll confirm whether it\'s a defect shortly.')
            print(f'{ident}: -> triaging ({rid})')
            continue

        ph = tk['phase']

        if ph == 'triaging':
            if now - tk['since'] < 120:  # grace: pid file + first tokens take a moment
                continue
            if not run_finished(tk['session']):
                if now - tk['since'] > POLL_TIMEOUT_NOTE_S:
                    ntfy(f'UAT {ident}: triage run quiet >6h')
                    tk['since'] = now
                continue
            msgs = run_log(tk['session'])
            m = VERDICT_RX.search(msgs)
            if not m:
                if respawn_or_fail(st, tk, ident, iid, 'triage'):
                    rid = spawn_or_fail(st, tk, ident, iid, triage_prompt(iss),
                                        f'triage-{ident}', REPO, TRIAGE_MODEL)
                    print(f'{ident}: triage respawned ({rid})')
                save_state(st)
                continue
            expl = (re.split(r'EXPLANATION:', msgs, flags=re.I)[-1]
                    .split('TECH:')[0].strip()[:800] if 'EXPLANATION' in msgs.upper() else '')
            if m.group(1).upper() == 'ACCEPT':
                tech = (msgs.split('TECH:')[-1].strip().splitlines()[0]
                        if 'TECH:' in msgs else iss['title'])
                r = sh('gh', 'issue', 'create', '--repo', GH_REPO,
                       '--title', f"[UAT] {iss['title']}",
                       '--label', 'uat-ticket', '--label', 'uat-confirmed',
                       '--body', f"From Linear {ident}.\n\n{iss.get('description') or iss['title']}\n\nTech: {tech}")
                gh_url = r.stdout.strip().splitlines()[-1]
                gh_num = int(re.search(r'/issues/(\d+)', gh_url).group(1))
                tk.update(phase='spawn_fix', gh=gh_num, gh_url=gh_url,
                          tech=tech, gh_title=iss['title'], spawn_tries=0)
                comment(iid, f'Confirmed — this is a real issue. Tracking the fix in {gh_url}; '
                             'I\'ll post a video here once it\'s working.')
                if inprog:
                    set_state(iid, inprog)
                print(f'{ident}: accepted -> {gh_url}')
            else:
                body = ('I looked at this one and it actually matches the spec — ' +
                        (expl or 'see the spec section referenced above.') +
                        '\n\nIf I\'ve misunderstood what you meant, reply here with a bit '
                        'more detail and I\'ll take another look. (cc: Bruce)')
                comment(iid, body)
                ntfy(f'UAT pushback on {ident}: {iss["title"][:80]}')
                tk.update(phase='declined', since=now)
                print(f'{ident}: pushback')
            save_state(st)

        elif ph == 'declined':
            # tester replied after pushback -> re-triage once
            cs = [c for c in comments(iid) if not (c.get('user') or {}).get('isMe')]
            if cs:
                last_ts = max(parse_ts(c['createdAt']) for c in cs)
                if last_ts > tk.get('since', 0):
                    iss2 = dict(iss)
                    iss2['description'] = (iss.get('description') or '') + \
                        '\n\nTester follow-up: ' + cs[-1]['body']
                    rid = acp_spawn(triage_prompt(iss2), f'retriage-{ident}', REPO, TRIAGE_MODEL)
                    tk.update(phase='triaging', session=rid, since=now, spawn_tries=0)
                    save_state(st)

        elif ph == 'spawn_fix':
            if fixing_count >= MAX_CONCURRENT_FIX:
                continue  # serialize fix runs; triages may run in parallel
            branch = f'uat/{tk["gh"]}'
            try:
                wt = make_worktree(branch, tk['gh'])
            except Exception as e:
                ntfy(f'UAT {ident}: worktree failed: {str(e)[:120]}')
                continue
            video_dir = os.path.join(RUNS_DIR, f'video-{ident}')
            os.makedirs(video_dir, exist_ok=True)
            rid = acp_spawn(fix_prompt(tk['gh_url'], ident, tk.get('tech', ''),
                                       branch, wt, video_dir),
                            f'fix-{ident}', wt, FIX_MODEL)
            tk.update(phase='fixing', session=rid, worktree=wt, branch=branch,
                      video_dir=video_dir, since=now, spawn_tries=0)
            fixing_count += 1
            save_state(st)
            print(f'{ident}: -> fixing ({rid})')

        elif ph == 'fixing':
            if now - tk['since'] < 120:
                continue
            if not run_finished(tk['session']):
                if now - tk['since'] > POLL_TIMEOUT_NOTE_S:
                    ntfy(f'UAT {ident}: fix run quiet >6h')
                    tk['since'] = now
                    save_state(st)
                continue
            msgs = run_log(tk['session'])
            kill_run_leftovers(tk.get('worktree'))
            if 'UAT-NO-REPRO' in msgs:
                expl = msgs.split('UAT-NO-REPRO', 1)[-1].strip()[:700]
                comment(iid, 'I dug into this properly and could not reproduce the problem — '
                             + (expl or 'the behaviour looks correct on staging.') +
                             '\n\nIf you can still see it, reply with a screenshot or the exact '
                             'page and I\'ll take another pass. (cc: Bruce)')
                ntfy(f'UAT {ident}: fix reported NO-REPRO')
                tk.update(phase='declined', since=now)
                save_state(st)
                print(f'{ident}: fix no-repro -> declined')
                continue
            if not DONE_RX.search(msgs):
                if respawn_or_fail(st, tk, ident, iid, 'fix'):
                    tk['phase'] = 'spawn_fix'  # fresh worktree + run
                    print(f'{ident}: fix respawn queued')
                save_state(st)
                continue
            video = find_video(tk['session'], tk.get('worktree'))
            try:
                asset = linear_upload(video) if video else None
            except Exception as e:
                ntfy(f'UAT {ident}: video upload failed after retries: {str(e)[:100]}')
                asset = None
            body = ('Here\'s the fix working: ' + (asset or '(video upload failed — see PR link)')
                    + '\n\nDoes this look right? Reply here to approve and I\'ll merge it, '
                      'or tell me what still looks off.')
            comment(iid, body)
            tk.update(phase='awaiting_approval', since=now, nudge=0)
            save_state(st)
            print(f'{ident}: -> awaiting_approval')

        elif ph == 'awaiting_approval':
            trivial = any(l['name'] == 'uat-trivial' for l in iss['labels']['nodes'])
            cs = [c for c in comments(iid) if not (c.get('user') or {}).get('isMe')]
            approved = trivial or (cs and is_approval(cs[-1]['body']))
            if approved:
                try:
                    pr_url = open_pr(tk)
                except Exception as e:
                    ntfy(f'UAT {ident}: open_pr failed: {str(e)[:160]}')
                    continue
                tk.update(phase='pr', pr=pr_url, since=now)
                comment(iid, f'Approved — PR open: {pr_url} — merging once CI and review pass.')
                print(f'{ident}: approved -> pr {pr_url}')
            elif now - tk['since'] > NUDGE_AFTER_S and not tk.get('nudge'):
                comment(iid, 'Just nudging — does the fix in the video above look right? '
                             'Reply yes to approve, or tell me what\'s still off.')
                tk['nudge'] = now
            else:
                continue
            save_state(st)

        elif ph == 'pr_pending':
            # legacy phase from cloud-session runs; treat as approved -> open PR
            try:
                pr_url = open_pr(tk)
            except Exception as e:
                ntfy(f'UAT {ident}: open_pr failed: {str(e)[:160]}')
                continue
            tk.update(phase='pr', pr=pr_url, since=now)
            comment(iid, f'PR open: {pr_url} — merging once CI and review pass.')
            save_state(st)

        elif ph == 'pr':
            num = int(re.search(r'/pull/(\d+)', tk['pr']).group(1))
            r = sh('gh', 'pr', 'view', str(num), '--repo', GH_REPO,
                   '--json', 'state,statusCheckRollup', check=False)
            try:
                pr = json.loads(r.stdout)
            except Exception:
                continue
            if pr.get('state') == 'MERGED':
                comment(iid, 'Merged — it reaches staging with the next deploy. Thanks for the report!')
                if team_state_id(t, 'done'):
                    set_state(iid, team_state_id(t, 'done'))
                tk['phase'] = 'done'
                if tk.get('worktree'):
                    sh('git', '-C', REPO, 'worktree', 'remove', '--force',
                       tk['worktree'], check=False)
                save_state(st)
                print(f'{ident}: merged -> done')
            elif pr.get('state') == 'CLOSED':
                tk['phase'] = 'done'
                save_state(st)


def parse_ts(s):
    import datetime
    try:
        return datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
    except Exception:
        return 0


def setup():
    if not LINEAR_KEY:
        sys.exit('LINEAR_API_KEY not set — fill ~/.secrets/linear.env')
    d = gql('query{teams{nodes{id key name states{nodes{id name type}}}}}'
            '{viewer{name email}}') if False else \
        gql('query{viewer{name email} teams{nodes{id key name states{nodes{id name type}}}}}')
    print('viewer:', d['viewer'])
    for t in d['teams']['nodes']:
        print(f"team {t['key']:8} {t['name']:24} states: "
              + ', '.join(s['name'] for s in t['states']['nodes']))
    # uat label so the watcher only picks up UAT tickets
    try:
        tid = team()['id']
        gql('''mutation($t:String!,$n:String!,$c:String!){issueLabelCreate(
            input:{teamId:$t,name:$n,color:$c}){success issueLabel{id}}}''',
            {'t': tid, 'n': UAT_LABEL, 'c': '#f2c94c'})
        print(f"label '{UAT_LABEL}' created on team {TEAM_KEY}")
    except SystemExit as e:
        print('label create:', e)
    # intake template for structured questions
    try:
        gql('''mutation($t:String!){templateCreate(input:{teamId:$t,type:"issue",
            name:"UAT report",description:"Report something that looks wrong",
            templateData:"{\\\"description\\\":\\\"**What happened:**\\\\n\\\\n**What you expected:**\\\\n\\\\n**Which page or screen:**\\\\n\\\\n**Screenshot:** attach it below\\\"}"}){template{id}}}''',
            {'t': tid})
        print('intake template created (team settings -> templates)')
    except SystemExit as e:
        print('template create:', e)


if __name__ == '__main__':
    if '--invite' in sys.argv:
        # uat_watcher.py --invite someone@example.com
        email = sys.argv[sys.argv.index('--invite') + 1]
        tid = team()['id']
        d = gql('''mutation($e:String!,$r:UserRoleType!,$t:[String!]!){
            organizationInviteCreate(input:{email:$e,role:$r,teamIds:$t}){
              success organizationInvite{id email}}}''',
            {'e': email, 'r': 'admin', 't': [tid]})  # free plan only allows admin invites
        print('invited:', d)
    elif '--setup' in sys.argv:
        setup()
    elif '--status' in sys.argv:
        st = load_state()
        for iid, tk in st['tickets'].items():
            alive = '' if tk['phase'] in ('done', 'failed', 'declined') else \
                (' [running]' if not run_finished(tk.get('session', '')) else ' [ended]')
            print(tk.get('id', iid), '->', tk['phase'],
                  (tk.get('session') or '')[:30], alive)
    else:
        st = load_state()
        tick(st)
        save_state(st)
