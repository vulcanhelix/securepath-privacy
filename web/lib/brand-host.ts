import { BASE_URL } from './base-url';

// ---------------------------------------------------------------------------
// W2-15 — FR-BRN-02 host → partner-subdomain resolution.
//
// Pure string work, no server imports: middleware.ts (edge) and the server
// components share this. A request on <sub>.<platform-domain> or
// <sub>.localhost (dev/CI — *.localhost resolves to loopback) carries the
// partner subdomain as its first label; anything else (apex domain, IP,
// unknown host) is the platform's own brand.
//
// Custom domains are deliberately NOT here: R1 is subdomains only, custom
// domain + auto-TLS is the deferred plan §6 manual-approval item.
// ---------------------------------------------------------------------------

const SUB_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
const RESERVED = new Set(['www', 'app', 'api', 'mail', 'auth', 'rest']);

const clean = (sub: string | null | undefined): string | null =>
  sub && SUB_RE.test(sub) && !RESERVED.has(sub) ? sub : null;

const defaultPlatformHost = (): string => {
  try {
    return new URL(BASE_URL).hostname.toLowerCase();
  } catch {
    return '';
  }
};

/**
 * Host header (with or without port) → partner subdomain, or null.
 * `platformDomain` defaults to BASE_URL's hostname — injectable for tests.
 */
export function partnerSubdomainFromHost(
  host: string | null | undefined,
  platformDomain?: string,
): string | null {
  if (!host) return null;
  const h = host.toLowerCase().split(':')[0].trim();
  if (!h || h === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(h)) return null;

  // dev/CI: <sub>.localhost
  if (h.endsWith('.localhost')) return clean(h.slice(0, -'.localhost'.length));

  // prod: <sub>.<platform domain> — exactly one extra label, never deeper
  const platformHost = platformDomain?.toLowerCase() ?? defaultPlatformHost();
  if (platformHost && h.endsWith('.' + platformHost)) {
    const sub = h.slice(0, -(platformHost.length + 1));
    return sub.includes('.') ? null : clean(sub);
  }
  return null;
}

/**
 * Origin a redirect may safely use: the request's own origin when its host
 * carries a partner subdomain (so an unauthenticated deep link lands on the
 * branded sign-in), otherwise the canonical BASE_URL — the hard rule from the
 * Caddy localhost:3200 redirect bugs still stands for every other case.
 */
export function brandAwareOrigin(host: string | null | undefined, requestOrigin: string): string {
  return partnerSubdomainFromHost(host) ? requestOrigin : BASE_URL;
}
