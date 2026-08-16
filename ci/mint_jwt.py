#!/usr/bin/env python3
"""Mint a Supabase-style HS256 JWT for CI (anon / service_role). Stdlib only.

Usage: mint_jwt.py <jwt-secret> <role>
"""
import base64, hashlib, hmac, json, sys, time


def b64(d: bytes) -> bytes:
    return base64.urlsafe_b64encode(d).rstrip(b'=')


def mint(secret: str, role: str) -> str:
    now = int(time.time())
    header = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    payload = b64(json.dumps({'role': role, 'iss': 'supabase', 'iat': now, 'exp': now + 86400 * 30}).encode())
    sig = b64(hmac.new(secret.encode(), header + b'.' + payload, hashlib.sha256).digest())
    return (header + b'.' + payload + b'.' + sig).decode()


if __name__ == '__main__':
    print(mint(sys.argv[1], sys.argv[2]))
