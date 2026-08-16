import { S3Client, PutObjectCommand, GetObjectCommand, HeadBucketCommand, CreateBucketCommand } from '@aws-sdk/client-s3';

// Portable object storage: MinIO on staging, AWS S3 af-south-1 at prod — same code,
// swapped by env (S3_ENDPOINT/S3_REGION/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY).
const BUCKET = process.env.S3_BUCKET ?? 'securepath-documents';

const s3 = new S3Client({
  region: process.env.S3_REGION ?? 'us-east-1',
  endpoint: process.env.S3_ENDPOINT || undefined,       // unset for real AWS
  forcePathStyle: process.env.S3_FORCE_PATH_STYLE === 'true',
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY!,
    secretAccessKey: process.env.S3_SECRET_KEY!,
  },
});

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

export async function putObject(key: string, body: Uint8Array, contentType: string) {
  await ensureBucket();
  await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: key, Body: body, ContentType: contentType }));
}

// Stream the object back through our server (works identically for MinIO on loopback and
// AWS S3 — no public bucket, download always passes our access check first).
export async function getObject(key: string) {
  const out = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
  return {
    body: out.Body as ReadableStream,
    contentType: out.ContentType ?? 'application/octet-stream',
  };
}
