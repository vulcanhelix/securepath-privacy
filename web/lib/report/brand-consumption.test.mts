// W2-15 — unit coverage for the brand-consumption plumbing that CI can't see
// end-to-end (Resend is not configured in the e2e stack, so the branded mail
// envelope is proven here; host→subdomain parsing is pure).
import test from 'node:test';
import assert from 'node:assert/strict';
import { partnerSubdomainFromHost, brandAwareOrigin } from '../brand-host';
import { envelope, esc, partnerBaseUrl, senderName } from '../branded-mail';

test('host → partner subdomain: *.localhost (dev/CI)', () => {
  assert.equal(partnerSubdomainFromHost('testfix-a.localhost:8080'), 'testfix-a');
  assert.equal(partnerSubdomainFromHost('testfix-a.localhost'), 'testfix-a');
});

test('host → partner subdomain: <sub>.<platform domain>', () => {
  assert.equal(partnerSubdomainFromHost('acme.securepath.dev', 'securepath.dev'), 'acme');
  assert.equal(partnerSubdomainFromHost('acme.securepath.dev:443', 'securepath.dev'), 'acme');
});

test('non-partner hosts resolve to nothing (platform chrome)', () => {
  for (const h of [
    null, undefined, '', 'localhost', 'localhost:8080', '127.0.0.1:8080',
    'securepath.dev',          // apex
    'a.b.securepath.dev',      // deeper than one label — not a partner host
    'www.securepath.dev',      // reserved label
    'unrelated.example.com',
    'testfix a.localhost',     // invalid label char
  ]) {
    assert.equal(partnerSubdomainFromHost(h, 'securepath.dev'), null, JSON.stringify(h));
  }
});

test('redirects keep the request origin only on partner hosts', () => {
  const base = process.env.APP_URL ?? 'https://securepath.dev';
  assert.equal(
    brandAwareOrigin('testfix-a.localhost:8080', 'http://testfix-a.localhost:8080'),
    'http://testfix-a.localhost:8080');
  // apex/IP hosts still take BASE_URL — the Caddy localhost:3200 rule stands
  assert.equal(brandAwareOrigin('127.0.0.1:8080', 'http://127.0.0.1:8080'), base);
  assert.equal(brandAwareOrigin('securepath.dev', 'https://securepath.dev'), base);
});

const BRAND = {
  name: 'TESTFIX Partner A',
  logo_url: 'https://testfix.invalid/logo.png',
  accent_hex: '#2255AA',
  primary_hex: '#101B33',
  email_sender_name: 'Partner A Support',
  support_contact: 'support@testfix.test',
};

test('the branded envelope carries name, logo, accent and support contact', () => {
  const html = envelope(BRAND, '<p>hi</p>');
  assert.match(html, /background:#2255AA/);              // accent bar
  assert.match(html, /testfix\.invalid\/logo\.png/);    // logo
  assert.match(html, /<strong>TESTFIX Partner A<\/strong>/);
  assert.match(html, /Support: support@testfix\.test/);
  assert.match(html, /Sent by TESTFIX Partner A via SecurePath/);
});

test('a null brand degrades to the SecurePath envelope', () => {
  const html = envelope(null, '<p>hi</p>');
  assert.match(html, /<strong>SecurePath<\/strong>/);
  assert.doesNotMatch(html, /Support:/);
});

test('envelope escapes brand fields (stored values are partner-supplied)', () => {
  const html = envelope({ ...BRAND, name: 'A <img onerror=x>', logo_url: 'https://x">q' }, '');
  assert.doesNotMatch(html, /A <img/);
  assert.match(html, /A &lt;img/);
});

test('sender name prefers email_sender_name, then display name', () => {
  assert.equal(senderName(BRAND), 'Partner A Support');
  assert.equal(senderName({ ...BRAND, email_sender_name: null }), 'TESTFIX Partner A');
  assert.equal(senderName(null), undefined);
});

test('emailed links land on the partner sign-in host when a subdomain is set', () => {
  const base = process.env.APP_URL ?? 'https://securepath.dev';
  const host = new URL(base).hostname;
  const loopback = host === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(host);
  const u = new URL(base);
  assert.equal(
    partnerBaseUrl({ ...BRAND, subdomain: 'testfix-a' }),
    `${u.protocol}//testfix-a.${loopback ? 'localhost' : host}${u.port ? `:${u.port}` : ''}`);
  assert.equal(partnerBaseUrl({ ...BRAND, subdomain: null }), base);
  assert.equal(partnerBaseUrl(null), base);
});

test('esc neutralises HTML metacharacters', () => {
  assert.equal(esc('<a "b" & \'>'), '&lt;a &quot;b&quot; &amp; &#39;&gt;');
});
