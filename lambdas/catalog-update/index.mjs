import Redis from "ioredis";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { parse } from "csv-parse/sync";

const {
  REDIS_ENDPOINT,
  REDIS_PORT = "6379",
  REDIS_TLS = "true",
  REDIS_AUTH_SECRET_ARN,
  CATALOG_BUCKET_NAME
} = process.env;

let redis;
let cachedToken;
const s3 = new S3Client({});

async function getRedisToken() {
  if (cachedToken) return cachedToken;
  const sm = new SecretsManagerClient({});
  const out = await sm.send(new GetSecretValueCommand({ SecretId: REDIS_AUTH_SECRET_ARN }));
  cachedToken = out.SecretString;
  return cachedToken;
}

async function getRedis() {
  if (redis) return redis;
  const password = await getRedisToken();
  redis = new Redis({
    host: REDIS_ENDPOINT,
    port: Number(REDIS_PORT),
    password,
    tls: REDIS_TLS === "true" ? {} : undefined,
    lazyConnect: true,
    connectTimeout: 8000
  });
  await redis.connect();
  return redis;
}

export const handler = async (event) => {
  try {
    const now = new Date().toISOString();

    let payload = {};
    if (event?.body) payload = typeof event.body === "string" ? JSON.parse(event.body) : event.body;

    const { csvBase64, csvText } = payload;
    if (!csvBase64 && !csvText) {
      return { statusCode: 400, headers: { "content-type": "application/json" }, body: JSON.stringify({ message: "Body must include csvBase64 or csvText" }) };
    }

    const csvBuffer = csvBase64 ? Buffer.from(csvBase64, "base64") : Buffer.from(csvText, "utf8");

    const s3Key = `catalog/${now}.csv`;
    await s3.send(new PutObjectCommand({ Bucket: CATALOG_BUCKET_NAME, Key: s3Key, Body: csvBuffer, ContentType: "text/csv" }));

    const records = parse(csvBuffer, { columns: true, skip_empty_lines: true, trim: true });

    const r = await getRedis();
    const tmpSet = "catalog:services:tmp";
    const servicesKey = "catalog:services";

    await r.del(tmpSet);
    const pipeline = r.pipeline();

    for (const row of records) {
      const id = String(row.id).trim();
      const serviceObj = {
        id,
        categoria: row.categoria,
        proveedor: row.proveedor,
        servicio: row.servicio,
        plan: row.plan,
        precio_mensual: Number(row.precio_mensual),
        detalles: row.detalles,
        estado: row.estado || "Activo"
      };
      pipeline.set(`catalog:service:${id}`, JSON.stringify(serviceObj));
      pipeline.sadd(tmpSet, id);
    }

    await pipeline.exec();
    await r.del(servicesKey);
    await r.sunionstore(servicesKey, tmpSet);
    await r.del(tmpSet);
    await r.set("catalog:last_sync", now);

    return { statusCode: 200, headers: { "content-type": "application/json" }, body: JSON.stringify({ items_count: records.length, last_sync: now, s3Key }) };
  } catch (err) {
    console.error("POST /catalog/update error", err);
    return { statusCode: 500, headers: { "content-type": "application/json" }, body: JSON.stringify({ message: "Internal error" }) };
  }
};
