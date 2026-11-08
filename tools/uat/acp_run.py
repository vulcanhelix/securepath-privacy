#!/usr/bin/env python3
"""acp_run.py — run one headless Devin task over ACP on this VPS.

Spawned detached by uat_watcher.py; writes agent output to a log file the
watcher polls. Auth: authenticate ACP call with _meta.api_key = the Devin
service key in /root/.secrets/devin.env (local CLI creds intentionally unused
in ACP mode). Runs the session in `bypass` mode = auto-approve all tools;
session/request_permission is still auto-answered defensively.

Usage:
  acp_run.py --prompt-file P --cwd DIR --model M --log LOGFILE
Log format: agent text lines verbatim; then a final 'ACP-RUN-END <stopReason>'.
"""

import argparse, json, os, select, subprocess, sys, time

SECRETS = '/root/.secrets/devin.env'
ISOLATED_HOME = '/root/uat-acp/home'


def devin_key():
    k = os.environ.get('DEVIN_API_KEY')
    if k:
        return k
    for line in open(SECRETS):
        if line.startswith('DEVIN_API_KEY='):
            return line.split('=', 1)[1].strip()
    sys.exit('DEVIN_API_KEY missing')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prompt-file', required=True)
    ap.add_argument('--cwd', required=True)
    ap.add_argument('--model', default='swe-2-max')
    ap.add_argument('--log', required=True)
    ap.add_argument('--max-seconds', type=int, default=3 * 3600)
    a = ap.parse_args()

    log = open(a.log, 'w', buffering=1)
    prompt = open(a.prompt_file).read()
    # Isolated HOME: empty mcp_config so ~20 org MCP servers don't stall every
    # session spawn; real credentials are never needed (auth = api_key call).
    env = dict(os.environ)
    env['HOME'] = ISOLATED_HOME
    err = open(a.log + '.err', 'w')
    p = subprocess.Popen(['devin', 'acp', '--model', a.model],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=err, text=True, cwd=a.cwd, env=env)
    print('PID', os.getpid(), file=open(a.log + '.pid', 'w'))
    deadline = time.time() + a.max_seconds
    next_id = [0]

    def rpc(method, params, timeout=60):
        next_id[0] += 1
        i = next_id[0]
        p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method,
                                  'params': params}) + '\n')
        p.stdin.flush()
        end = time.time() + timeout
        while time.time() < end:
            if p.poll() is not None:
                return {'error': 'acp process died'}
            if not select.select([p.stdout], [], [], 2)[0]:
                continue
            line = p.stdout.readline()
            if not line:
                return {'error': 'acp closed stdout'}
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get('id') == i:
                return m
            handle_server(m)
        return {'error': f'timeout on {method}'}

    def handle_server(m):
        # server->client requests: permission prompts and fs writes
        meth = m.get('method')
        if meth == 'session/request_permission' and 'id' in m:
            opts = m.get('params', {}).get('options') or []
            allow = next((o['optionId'] for o in opts if 'allow' in str(o.get('optionId'))),
                         opts[0]['optionId'] if opts else 'allow_once')
            respond(m['id'], {'outcome': {'outcome': 'selected', 'optionId': allow}})
        elif meth == 'session/update':
            upd = m.get('params', {}).get('update', {})
            if upd.get('sessionUpdate') == 'agent_message_chunk':
                c = upd.get('content') or {}
                texts = []
                if isinstance(c, dict) and c.get('type') == 'text':
                    texts.append(c.get('text', ''))
                elif isinstance(c, dict):  # defensive: nested content list
                    texts += [x['text'] for x in (c.get('content') or [])
                              if isinstance(x, dict) and x.get('type') == 'text']
                if texts:
                    log.write(''.join(texts))
                    log.flush()

    def respond(i, result):
        p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'result': result}) + '\n')
        p.stdin.flush()

    try:
        # No fs/terminal client capabilities: the agent must use its own
        # built-in tools. Declaring them lets it delegate fs/terminal to this
        # client — unanswered, that deadlocks the turn.
        r = rpc('initialize', {'protocolVersion': 1, 'clientCapabilities': {}})
        if 'error' in r:
            sys.exit(f'init failed: {r}')
        r = rpc('authenticate', {'methodId': 'devin-browser',
                                 '_meta': {'api_key': devin_key()}}, timeout=90)
        if 'error' in r or 'result' not in r:
            sys.exit(f'auth failed: {r}')
        r = rpc('session/new', {'cwd': a.cwd, 'mcpServers': []}, timeout=90)
        if 'result' not in r:
            sys.exit(f'session/new failed: {r}')
        sid = r['result']['sessionId']
        rpc('session/set_mode', {'sessionId': sid, 'modeId': 'bypass'}, timeout=20)
        r = rpc('session/prompt',
                {'sessionId': sid,
                 'prompt': [{'type': 'text', 'text': prompt}]},
                timeout=max(60, deadline - time.time()))
        sr = (r.get('result') or {}).get('stopReason', r.get('error', 'unknown'))
        log.write(f'\nACP-RUN-END {sr}\n')
    finally:
        try:
            p.kill()
        except Exception:
            pass


if __name__ == '__main__':
    main()
