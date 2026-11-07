import { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand, HeadObjectCommand, HeadBucketCommand, CreateBucketCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

// Portable object storage: MinIO on staging, AWS S3 af-south-1 at prod — same code,
// swapped by env (S3_ENDPOINT/S3_REGION/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY).
//
// W4-09 (NFR-02): evidence files are served ONLY through short-lived signed URLs,
// issued after the app's permission check — the bytes never transit the Next server.
// Direct uploads are presigned PUTs pinned to one key + one SHA-256 (the store
// rejects bytes that don't match — MinIO & S3 enforce x-amz-checksum-sha256), so
// the content-addressed key convention (<client_org_id>/<sha256>) is guaranteed
// by the store itself and stays tenant-scoped.
//
// Env:
//   S3_ENDPOINT          server-side endpoint (loopback MinIO on staging)
//   S3_BROWSER_ENDPOINT  the endpoint clients/browsers can reach — presigned URLs
//                        are signed against THIS host (defaults to S3_ENDPOINT).
//                        Staging must expose MinIO publicly (e.g. Caddy
//                        objects.securepath.dev → minio) and set this, or signed
//                        links land on loopback. Prod = real AWS S3 URL.
//   S3_URL_TTL           seconds a signed URL lives (default 300 for PUT, 60 GET)
//   S3_SSE               optional 'AES256'|'aws:kms' → signed into PUTs so the
//                        store requires server-side encryption at rest (NFR-02);
//                        leave unset on MinIO-without-KMS. Prod: bucket default
//                        SSE is the real guarantee — this belt-and-braces it.
const BUCKET = process.env.S3_BUCKET ?? 'securepath-documents';
const CREDS = {
  accessKeyId: process.env.S3_ACCESS_KEY!,
  secretAccessKey: process.env.S3_SECRET_KEY!,
};
const SSE = process.env.S3_SSE || undefined;

// server-side ops (bucket ensure, head, generated-artifact puts, deletes)
const s3 = new S3Client({
  region: process.env.S3_REGION ?? 'us-east-1',
  endpoint: process.env.S3_ENDPOINT || undefined,       // unset for real AWS
  forcePathStyle: process.env.S3_FORCE_PATH_STYLE === 'true',
  credentials: CREDS,
});

// presigning — signature is computed for the host a CLIENT reaches, which can
// differ from the server's loopback view (S3_BROWSER_ENDPOINT).
const s3Sign = new S3Client({
  region: process.env.S3_REGION ?? 'us-east-1',
  endpoint: (process.env.S3_BROWSER_ENDPOINT || process.env.S3_ENDPOINT) || undefined,
  forcePathStyle: process.env.S3_FORCE_PATH_STYLE === 'true',
  credentials: CREDS,
});

export const UPLOAD_URL_TTL = Math.max(30, Number(process.env.S3_URL_TTL) || 300);
export const DOWNLOAD_URL_TTL = Math.min(UPLOAD_URL_TTL, 60); // downloads are follow-on-click: shortest

let bucketReady = false;
async function ensureBucket() {
  if (bucketReady) return;
  try {
    await s3.send(new HeadBucketCommand({ Bucket: BUCKET }));
  } catch {
    try { await s3.send(new CreateBucketCommand({ Bucket: BUCKET })); } catch {}
  }
  bucketReady = true;
}

// Server-generated artifacts only (issued policies/reports/manuals — there is no
// client byte stream to presign). Client uploads go through presignUpload.
export async function putObject(key: string, body: Uint8Array, contentType: string) {
  await ensureBucket();
  await s3.send(new PutObjectCommand({
    Bucket: BUCKET, Key: key, Body: body, ContentType: contentType,
    ...(SSE ? { ServerSideEncryption: SSE as 'AES256' | 'aws:kms' } : {}),
  }));
}

// Only ever called after delete_document() in Postgres has allowed the delete —
// confirmed evidence never reaches here.
export async function deleteObject(key: string) {
  await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: key }));
}

// Existence/size/stored-checksum of an object — the register step's verification
// that the direct upload really landed (and that its bytes match the claimed key
// when the store recorded a checksum).
export async function headObject(key: string) {
  try {
    const out = await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key, ChecksumMode: 'ENABLED' }));
    return {
      size: out.ContentLength ?? 0,
      contentType: out.ContentType ?? 'application/octet-stream',
      checksumSha256: out.ChecksumSHA256 ?? null, // base64 — stored only when the PUT carried it
    };
  } catch {
    return null;
  }
}

// W4-09 — presigned PUT for one tenant-scoped key. The returned headers MUST be
// sent verbatim with the PUT: x-amz-checksum-sha256 is a signed header and the
// store validates the body against it (verified: MinIO 2025.4.22 → 400
// XAmzContentChecksumMismatch), so a signed key can never hold foreign bytes.
export async function presignUpload(key: string, contentType: string, sha256Base64: string) {
  await ensureBucket();
  const url = await getSignedUrl(s3Sign, new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    ContentType: contentType,
    ChecksumSHA256: sha256Base64,
    ...(SSE ? { ServerSideEncryption: SSE as 'AES256' | 'aws:kms' } : {}),
  }), { expiresIn: UPLOAD_URL_TTL });
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'x-amz-checksum-sha256': sha256Base64,
  };
  if (SSE) headers['x-amz-server-side-encryption'] = SSE;
  return { url, headers, expires_in: UPLOAD_URL_TTL };
}

// W4-09 — presigned GET for one key, with the download filename + disposition
// signed in (S3 response-content-* overrides). Issued ONLY after the API route's
// RLS permission check and the W4-03 scan gate; TTL is 60s — long enough to
// start the download, useless for sharing.
export async function presignDownload(key: string, filename: string, mime: string, inline: boolean) {
  const safe = filename.replace(/[^\w.\- ]/g, '_').replace(/"/g, '_');
  return getSignedUrl(s3Sign, new GetObjectCommand({
    Bucket: BUCKET,
    Key: key,
    ResponseContentType: mime,
    ResponseContentDisposition: `${inline ? 'inline' : 'attachment'}; filename="${safe}"`,
  }), { expiresIn: DOWNLOAD_URL_TTL });
}
