import Redis from "ioredis";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const {
  REDIS_ENDPOINT,
  REDIS_PORT = "6379",
  REDIS_TLS = "true",
  REDIS_AUTH_SECRET_ARN
} = process.env;

let redis;
let cachedToken;

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

export const handler = async () => {
  try {
    const r = await getRedis();
    const lastSync = await r.get("catalog:last_sync");
    const serviceIds = await r.smembers("catalog:services");

    if (!serviceIds?.length) {
      return {
        statusCode: 200,
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ last_sync: lastSync, items: [] })
      };
    }

    const pipeline = r.pipeline();
    serviceIds.forEach(id => pipeline.get(`catalog:service:${id}`));
    const raw = await pipeline.exec();

    const items = raw
      .map(([err, val]) => (err ? null : val))
      .filter(Boolean)
      .map(JSON.parse)
      .filter(s => s.estado === "Activo");

    return {
      statusCode: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ last_sync: lastSync, items })
    };
  } catch (err) {
    console.error("GET /catalog error", err);
    return { statusCode: 500, headers: { "content-type": "application/json" }, body: JSON.stringify({ message: "Internal error" }) };
  }
};
