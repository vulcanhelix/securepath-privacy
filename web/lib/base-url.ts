// Public origin for redirects/links; req.url behind Caddy is the internal host.
export const BASE_URL = process.env.APP_URL ?? 'https://securepath.dev';
