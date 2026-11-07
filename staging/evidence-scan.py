#!/usr/bin/env python3
"""W4-03 — malware scan worker for staging.

Claims pending rows from public.malware_scan_queue (evidence_items.file_key +
documents.storage_path objects in the S3/MinIO store), streams each object to
clamd INSTREAM, and records the verdict via public.resolve_malware_scan:

    clean    → object passed; evidence/document becomes acceptable
    infected → quarantine state: verify/accept refuse + uploader/partner_admin
               notification + audit row (all inside resolve_malware_scan)
    error    → fetch/engine failure; retried ×3 by the RPC, then 'failed'

Install on this VPS (jobs-tick pattern):

    sudo cp staging/evidence-scan.py /opt/securepath/evidence-scan.py
    sudo chmod +x /opt/securepath/evidence-scan.py
    sudo cp staging/evidence-scan.service staging/evidence-scan.timer \
        /etc/systemd/system/
    sudo systemctl daemon-reload && sudo systemctl enable --now evidence-scan.timer
    docker pull minio/mc:latest            # one-time object-fetch client

Env (all optional — defaults fit this compose):
    CLAMD_HOST/CLAMD_PORT   clamd TCP endpoint (default 127.0.0.1:3310)
    SCAN_DB_CONTAINER       postgres container name (securepath-staging-db-1)
    SCAN_NETWORK            compose network for the mc client (securepath-staging_default)
    SCAN_BUCKET             S3 bucket (S3_BUCKET env or securepath-documents)
    SCAN_BATCH              rows per claim (default 20)
    SCAN_ROUNDS             max claim rounds per tick (default 5)
    MC_IMAGE                minio client image (minio/mc:latest)
    SCAN_ENV_FILE           .env path (default: ../staging/.env next to the script,
                            or /opt/securepath/../staging/.env — set explicitly
                            when installed to /opt/securepath)
"""
import os, socket, struct, subprocess, sys, urllib.parse

DB = os.environ.get('SCAN_DB_CONTAINER', 'securepath-staging-db-1')
NET = os.environ.get('SCAN_NETWORK', 'securepath-staging_default')
MC_IMAGE = os.environ.get('MC_IMAGE', 'minio/mc:latest')
CLAMD_HOST = os.environ.get('CLAMD_HOST', '127.0.0.1')
CLAMD_PORT = int(os.environ.get('CLAMD_PORT', '3310'))
BATCH = int(os.environ.get('SCAN_BATCH', '20'))
ROUNDS = int(os.environ.get('SCAN_ROUNDS', '5'))
CHUNK = 1024 * 1024  # INSTREAM chunk size (1 MiB)


def env_file():
    # secrets live in the compose .env; when installed to /opt/securepath the
    # unit sets SCAN_ENV_FILE to the real path
    return os.environ.get(
        'SCAN_ENV_FILE',
        os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))


def read_env(path):
    out = {}
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return out


ENV = read_env(env_file())
PGPW = ENV.get('POSTGRES_PASSWORD', '')
MINIO_USER = ENV.get('MINIO_ROOT_USER', '')
MINIO_PASS = ENV.get('MINIO_ROOT_PASSWORD', '')
BUCKET = os.environ.get('SCAN_BUCKET') or ENV.get('S3_BUCKET', 'securepath-documents')


def log(msg):
    print(f'evidence-scan: {msg}', flush=True)


def psql(sql):
    """Run a statement inside the db container as supabase_admin."""
    r = subprocess.run(
        ['docker', 'exec', '-i', '-e', f'PGPASSWORD={PGPW}', DB,
         'psql', '-h', '127.0.0.1', '-U', 'supabase_admin', '-d', 'postgres',
         '-v', 'ON_ERROR_STOP=1', '-tA', '-c', sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'psql failed: {r.stderr.strip()[:400]}')
    return r.stdout.strip()


def claim(n):
    out = psql(
        "SELECT subject_type || '|' || subject_id || '|' || object_key "
        f"FROM public.claim_malware_scans({int(n)}) ORDER BY enqueued_at")
    rows = []
    for line in out.splitlines():
        parts = line.split('|', 2)
        if len(parts) == 3:
            rows.append(tuple(parts))
    return rows


def fetch_object(key):
    """Stream object bytes via minio/mc on the compose network. Returns
    (proc_stdout_iter, error_str)."""
    alias = ('http://'
             + urllib.parse.quote(MINIO_USER, safe='') + ':'
             + urllib.parse.quote(MINIO_PASS, safe='')
             + '@minio:9000')
    cmd = ['docker', 'run', '--rm', '-i', '--network', NET,
           '-e', f'MC_HOST_local={alias}',
           MC_IMAGE, '--quiet', 'cat', f'local/{BUCKET}/{key}']
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return proc, None
    except OSError as e:
        return None, f'mc launch failed: {e}'


def scan_stream(chunks):
    """Drive clamd INSTREAM over TCP. chunks = iterable of bytes.
    Returns (verdict, detail): ('clean'|'infected'|'error', str)."""
    try:
        s = socket.create_connection((CLAMD_HOST, CLAMD_PORT), timeout=120)
    except OSError as e:
        return 'error', f'clamd connect failed: {e}'
    try:
        with s:
            s.sendall(b'zINSTREAM\x00')
            for data in chunks:
                if not data:
                    continue
                s.sendall(struct.pack('>I', len(data)) + data)
            s.sendall(struct.pack('>I', 0))
            resp = b''
            while True:
                b = s.recv(4096)
                if not b:
                    break
                resp += b
    except OSError as e:
        return 'error', f'clamd io failed: {e}'
    text = resp.decode('utf-8', 'replace').strip()
    # clamd answers "<id>: stream: OK" | "<id>: stream: <signature> FOUND" | "... ERROR"
    if text.endswith('OK'):
        return 'clean', text
    if ' FOUND' in text or text.endswith('FOUND'):
        return 'infected', text
    return 'error', f'clamd answer: {text or "no response"}'


def resolve(subject_type, subject_id, verdict, detail):
    detail = (detail or '')[:500].replace("'", "''")
    psql("SELECT public.resolve_malware_scan("
         f"'{subject_type}','{subject_id}','{verdict}','{detail}')")


def scan_one(subject_type, subject_id, key):
    proc, err = fetch_object(key)
    if err:
        return 'error', err
    verdict, detail = scan_stream(iter(lambda: proc.stdout.read(CHUNK), b''))
    err_out = proc.stderr.read().decode('utf-8', 'replace').strip()
    rc = proc.wait()
    if rc != 0 and verdict == 'clean':
        # mc failed (missing object / auth) even though the stream looked empty
        return 'error', f'object fetch failed (mc rc={rc}): {err_out[:300]}'
    return verdict, detail


def main():
    # single-flight lock: a stale earlier run must not double-claim
    lockpath = '/tmp/evidence-scan.lock'
    import fcntl
    lockfd = open(lockpath, 'w')
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log('another run holds the lock — skipping tick')
        return 0

    total = 0
    for _ in range(ROUNDS):
        rows = claim(BATCH)
        if not rows:
            break
        for subject_type, subject_id, key in rows:
            try:
                verdict, detail = scan_one(subject_type, subject_id, key)
                resolve(subject_type, subject_id, verdict, detail)
                log(f'{subject_type} {subject_id} {key} -> {verdict} ({detail[:120]})')
            except Exception as e:            # never lose a row to a crash
                try:
                    resolve(subject_type, subject_id, 'error', f'worker crash: {e}')
                except Exception as e2:
                    log(f'RESOLVE FAILED for {subject_id}: {e2}')
                log(f'{subject_type} {subject_id} {key} -> error (worker crash: {e})')
            total += 1
    log(f'done — {total} object(s) processed this tick')
    return 0


if __name__ == '__main__':
    sys.exit(main())
