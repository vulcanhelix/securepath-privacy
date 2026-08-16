#!/usr/bin/env bash
# Reference SQL-level isolation suite (superseded by app/tests/e2e_isolation.py).
# Needs a fresh database each run — the seed is not idempotent.
# Separate psql invocations: DROP DATABASE cannot share a call with other statements.
set -euo pipefail
cd "$(dirname "$0")"
sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS securepath_poc"
sudo -u postgres psql -q -c "DROP ROLE IF EXISTS app_user"
sudo -u postgres psql -q -c "CREATE DATABASE securepath_poc"
sudo -u postgres psql -q -d securepath_poc -f schema.sql
sudo -u postgres psql -q -d securepath_poc -c "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_user"
sudo -u postgres psql -d securepath_poc -f test_isolation.sql 2>&1 | grep -E 'PASS|FAIL|PASSED'
