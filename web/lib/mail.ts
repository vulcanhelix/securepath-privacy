// App-transactional mail via Resend + ops alerts (email + ntfy).
// GoTrue auth mail (confirmations) goes through its own SMTP config, not this.

const RESEND_KEY = process.env.RESEND_API_KEY;
const FROM = process.env.MAIL_FROM ?? 'SecurePath <noreply@securepathconsulting.co.za>';
const OPS_EMAIL = process.env.OPS_ALERT_EMAIL ?? 'bruce.m@securepathconsulting.co.za';
const NTFY_TOPIC = process.env.NTFY_TOPIC;

export async function sendMail(to: string, subject: string, html: string) {
  if (!RESEND_KEY) { console.warn('RESEND_API_KEY unset; mail skipped:', subject); return; }
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) console.error('resend failed', r.status, await r.text());
}

export async function opsAlert(subject: string, body: string) {
  await Promise.allSettled([
    sendMail(OPS_EMAIL, subject, `<p>${body}</p>`),
    NTFY_TOPIC
      ? fetch(`https://ntfy.sh/${NTFY_TOPIC}`, { method: 'POST', headers: { Title: subject }, body })
      : Promise.resolve(),
  ]);
}
