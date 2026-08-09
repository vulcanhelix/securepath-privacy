/** @type {import('next').NextConfig} */
// Evidence uploads run through middleware, whose request body clone defaults to 10 MB and
// silently truncates larger multipart bodies. Keep it above the 25 MB upload cap.
export default { output: 'standalone', experimental: { middlewareClientMaxBodySize: '32mb' } };
