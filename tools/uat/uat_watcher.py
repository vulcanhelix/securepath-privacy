#!/usr/bin/env python3
"""uat_watcher.py — UAT feedback pipeline for SecurePath.

Runs via systemd timer every ~5 min. State machine:

  new Linear ticket (UAT team)
    -> triage: Devin session evaluates vs spec (reject only with citation)
    -> accept: GitHub issue labelled uat-ticket + uat-confirmed
    -> pushback: gentle Linear reply citing spec; Bruce pinged (ntfy + assign)
    -> fix: label-gated Devin session implements on branch + tests + video
    -> awaiting_approval: video posted to ticket; 48h nudge; tester approves
    -> pr_pending -> pr: session opens PR; merge on green CI + review
    -> done

Trivial tickets (label `uat-trivial`) skip the tester-approval gate.

State persists in /root/.local/state/uat-watcher/state.json — crash-safe.

Usage:
  uat_watcher.py --once          single poll pass (timer uses this)
  uat_watcher.py --setup         discover team/states, create intake template
  uat_watcher.py --status        print tracked tickets
"""

import json, os, re, subprocess, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.expanduser('~/.local/state/uat-watcher')
STATE_FILE = os.path.join(STATE_DIR, 'state.json')
DEVIN_PY = os.path.expanduser('~/.claude/skills/devin-chat/scripts/devin.py')
GH_REPO = 'vulcanhelix/securepath-privacy'
LINEAR_GQL = 'https://api.linear.app/graphql'
NTFY_TOPIC = 'securepath-ops-d2e6906f'
NUDGE_AFTER_S = 48 * 3600
POLL_TIMEOUT_NOTE_S = 6 * 3600  # warn if a devin session is quiet this long

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


def gql(query, variables=None):
    body = json.dumps({'query': query, 'variables': variables or {}}).encode()
    req = urllib.request.Request(LINEAR_GQL, data=body, method='POST', headers={
        'Authorization': LINEAR_KEY, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f'Linear API {e.code}: {e.read()[:300]}')
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


def devin_new(prompt, title):
    r = sh('python3', DEVIN_PY, 'new', prompt, '--yes', '--title', title, timeout=180)
    m = re.search(r'([0-9a-f]{32})', r.stdout)
    return m.group(1) if m else None


def devin_messages(session_id):
    r = sh('python3', DEVIN_PY, 'read', session_id, '--last', '40', check=False, timeout=120)
    return r.stdout


def devin_sections(msgs):
    """Only message bodies authored by Devin — the read dump includes the
    original prompt (which contains example verdict/PR lines), so never
    regex the raw dump."""
    parts = re.split(r'^--- (\w+) \d{2}-\d{2} \d{2}:\d{2}\n', msgs, flags=re.M)
    out = []
    for i in range(1, len(parts), 2):
        if parts[i] == 'devin':
            out.append(parts[i + 1])
    return out


def devin_send(session_id, text, wait=0):
    args = ['python3', DEVIN_PY, 'send', session_id, text]
    if wait:
        args += ['--wait', str(wait)]
    return sh(*args, check=False, timeout=wait + 120)


def devin_attachment(link, out_dir):
    r = sh('python3', DEVIN_PY, 'attachment', link, '--out', out_dir, check=False, timeout=180)
    m = re.search(r'saved (\S+)', r.stdout or '')
    return m.group(1) if m else None


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
    req = urllib.request.Request(url, data=open(path, 'rb').read(), method='PUT')
    req.add_header('Content-Type', 'video/mp4')
    for h in uf.get('headers') or []:
        req.add_header(h['key'], h['value'])
    urllib.request.urlopen(req, timeout=300)
    return asset


def triage_prompt(issue):
    return f"""You are the UAT triage for SecurePath (repo vulcanhelix/securepath-privacy,
spec docs/spec/SP-SPC-PLT-001_v0_2.txt). A UAT tester filed this ticket:

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

Reply with EXACTLY one verdict line, then a 2-4 sentence plain-language
explanation for the tester:
VERDICT: ACCEPT    or    VERDICT: PUSHBACK
Then "EXPLANATION:" and the text. On ACCEPT also append a one-line
technical summary prefixed "TECH:" for the fix session."""


def fix_prompt(gh_url, lin_ref, tech):
    return f"""Fix UAT issue {gh_url} in vulcanhelix/securepath-privacy.

Context: this came from UAT testing ({lin_ref}). Technical summary: {tech}

Rules:
- Work on a branch uat/<issue-number> off main. Do NOT merge to main.
- Implement the fix, run the relevant SQL/browser tests (see .github/workflows/e2e.yml
  and AGENTS.md). Add or update a test if the bug class lacks coverage.
- Record a ~30s playwright video proving the fix works on the live flow
  (web/ has playwright). Save it as an attachment and reply with:
    UAT-FIX-DONE
    PR: <leave unset for now>
  plus the attachment link for the video.
- Do NOT open the PR yet — a human approves the video first. When you get the
  follow-up message "UAT APPROVED — open PR", then push, open the PR, and reply
  with "PR: <url>". The merge gate (green CI + review) applies after that.
"""


def tick(st):
    if not LINEAR_KEY:
        print('LINEAR_API_KEY not set — fill ~/.secrets/linear.env')
        return
    t = team()
    st['teams'][TEAM_KEY] = {'id': t['id']}
    inprog = team_state_id(t, 'in progress')
    triage = team_state_id(t, 'triage', 'backlog')
    now = time.time()

    for iss in issues(t['id']):
        if not any(l['name'].lower() == UAT_LABEL for l in iss['labels']['nodes']):
            continue
        iid, ident = iss['id'], iss['identifier']
        tk = st['tickets'].get(iid)
        if not tk:
            # ignore tickets already terminal before we first saw them
            if iss['state']['type'] in ('completed', 'canceled'):
                continue
            sid = devin_new(triage_prompt(iss), f'UAT triage {ident}')
            st['tickets'][iid] = {'id': ident, 'phase': 'triaging',
                                  'session': sid, 'since': now}
            comment(iid, 'Thanks — looking at this now. I\'ll confirm whether it\'s a defect shortly.')
            print(f'{ident}: -> triaging ({sid})')
            continue

        ph = tk['phase']

        if ph == 'triaging':
            msgs = '\n'.join(devin_sections(devin_messages(tk['session'])))
            m = VERDICT_RX.search(msgs)
            if not m:
                if now - tk['since'] > POLL_TIMEOUT_NOTE_S:
                    ntfy(f'UAT {ident}: triage session quiet >6h')
                    tk['since'] = now
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
                tk.update(phase='spawn_fix', gh=gh_num, gh_url=gh_url, tech=tech)
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
                    sid = devin_new(triage_prompt(iss2), f'UAT re-triage {ident}')
                    tk.update(phase='triaging', session=sid, since=now)
                    save_state(st)

        elif ph == 'spawn_fix':
            sid = devin_new(fix_prompt(tk['gh_url'], ident, tk.get('tech', '')),
                            f'UAT fix {ident}')
            tk.update(phase='fixing', session=sid, since=now)
            save_state(st)
            print(f'{ident}: -> fixing ({sid})')

        elif ph == 'fixing':
            msgs = '\n'.join(devin_sections(devin_messages(tk['session'])))
            if not DONE_RX.search(msgs):
                if now - tk['since'] > POLL_TIMEOUT_NOTE_S:
                    ntfy(f'UAT {ident}: fix session quiet >6h')
                    tk['since'] = now
                    save_state(st)
                continue
            video = None
            for link in re.findall(r'https://\S*attachments/\S+', msgs):
                video = devin_attachment(link, STATE_DIR)
                if video:
                    break
            asset = linear_upload(video) if video else None
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
                devin_send(tk['session'], 'UAT APPROVED — open PR')
                tk.update(phase='pr_pending', since=now)
                comment(iid, 'Approved — opening the PR now, it goes through the normal review gate.')
                print(f'{ident}: approved -> pr_pending')
            elif now - tk['since'] > NUDGE_AFTER_S and not tk.get('nudge'):
                comment(iid, 'Just nudging — does the fix in the video above look right? '
                             'Reply yes to approve, or tell me what\'s still off.')
                tk['nudge'] = now
            else:
                continue
            save_state(st)

        elif ph == 'pr_pending':
            msgs = '\n'.join(devin_sections(devin_messages(tk['session'])))
            m = PR_RX.search(msgs)
            if m:
                tk.update(phase='pr', pr=m.group(1), since=now)
                comment(iid, f'PR open: {m.group(1)} — merging once CI and review pass.')
                save_state(st)
                print(f'{ident}: -> pr {m.group(1)}')
            elif now - tk['since'] > POLL_TIMEOUT_NOTE_S:
                ntfy(f'UAT {ident}: session quiet awaiting PR')
                tk['since'] = now
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
    if '--setup' in sys.argv:
        setup()
    elif '--status' in sys.argv:
        st = load_state()
        for iid, tk in st['tickets'].items():
            print(tk.get('id', iid), '->', tk['phase'], tk.get('session', '')[:12])
    else:
        st = load_state()
        tick(st)
        save_state(st)
