const { execFile } = require('child_process');
const { promisify } = require('util');
const fs = require('fs/promises');
const path = require('path');
const os = require('os');
const Redis = require('ioredis');

const execFileAsync = promisify(execFile);

const REDIS_HOST = process.env.REDIS_HOST || 'redis';
const REDIS_PORT = Number(process.env.REDIS_PORT || 6379);
const STREAM = process.env.REDIS_STREAM || 'jobs';
const GROUP = process.env.REDIS_GROUP || 'scrapers';
const CONSUMER = process.env.CONSUMER_NAME || os.hostname();
const RESULTS_DIR = process.env.RESULTS_DIR || '/results';
const CLAIM_IDLE_MS = Number(process.env.CLAIM_IDLE_MS || 15000);

const redis = new Redis({ host: REDIS_HOST, port: REDIS_PORT });
const scraperPath = path.join(__dirname, 'index.js');

function parseFields(rawFields) {
  const obj = {};
  for (let i = 0; i < rawFields.length; i += 2) {
    obj[rawFields[i]] = rawFields[i + 1];
  }
  return obj;
}

function sanitizeJobId(jobId) {
  if (!jobId || !/^[a-zA-Z0-9._-]+$/.test(jobId)) {
    throw new Error(`Invalid job_id: ${jobId}`);
  }
  return jobId;
}

async function isValidResultFile(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    const parsed = JSON.parse(content);
    return Array.isArray(parsed) && parsed.length > 0;
  } catch {
    return false;
  }
}

async function ensureGroup() {
  try {
    await redis.xgroup('CREATE', STREAM, GROUP, '0', 'MKSTREAM');
  } catch (err) {
    if (!err.message.includes('BUSYGROUP')) throw err;
  }
}

async function handleMessage(messageId, rawFields) {
  const { job_id: rawJobId, url } = parseFields(rawFields);
  const jobId = sanitizeJobId(rawJobId);
  if (!url) throw new Error(`Missing url for job_id=${jobId}`);

  const finalPath = path.join(RESULTS_DIR, `${jobId}.json`);
  const tmpPath = path.join(RESULTS_DIR, `.${jobId}.json.tmp`);

  console.log(`[worker-redis] Processing msg=${messageId} job_id=${jobId} url=${url}`);

  // Идемпотентность: повторная доставка того же job_id не перезаписывает готовый файл
  if (await isValidResultFile(finalPath)) {
    await fs.rm(tmpPath, { force: true });
    await redis.xack(STREAM, GROUP, messageId);
    console.log(`[worker-redis] Already valid ${finalPath}, XACKed ${messageId}`);
    return;
  }

  await fs.mkdir(RESULTS_DIR, { recursive: true });

  // Запускаем оригинальный скрапер, указывая ему писать сразу во временный файл
  const { stdout, stderr } = await execFileAsync('node', [scraperPath], {
    env: {
      ...process.env,
      SCRAPE_URL: url,
      OUTPUT_PATH: tmpPath,
    },
  });
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);

  if (!(await isValidResultFile(tmpPath))) {
    throw new Error(`Scraper produced invalid or empty file at ${tmpPath}`);
  }

  // Атомарное переименование в том же каталоге и XACK только после записи
  await fs.rename(tmpPath, finalPath);
  await redis.xack(STREAM, GROUP, messageId);
  console.log(`[worker-redis] Saved ${finalPath} and XACKed ${messageId}`);
}

async function processPendingOnStartup() {
  while (true) {
    const res = await redis.xreadgroup(
      'GROUP', GROUP, CONSUMER,
      'COUNT', 1,
      'STREAMS', STREAM, '0'
    );
    if (!res || !res[0] || res[0][1].length === 0) break;
    const [msgId, fields] = res[0][1][0];
    await handleMessage(msgId, fields);
  }

  const claimed = await redis.xautoclaim(STREAM, GROUP, CONSUMER, 0, '0-0', 'COUNT', 10);
  const messages = claimed && claimed[1] ? claimed[1] : [];
  for (const [msgId, fields] of messages) {
    if (fields) await handleMessage(msgId, fields);
  }
}

async function run() {
  await ensureGroup();
  console.log(`[worker-redis] Started consumer=${CONSUMER}`);
  await processPendingOnStartup();

  while (true) {
    try {
      const res = await redis.xreadgroup(
        'GROUP', GROUP, CONSUMER,
        'COUNT', 1,
        'BLOCK', 5000,
        'STREAMS', STREAM, '>'
      );

      if (res && res[0] && res[0][1].length > 0) {
        const [msgId, fields] = res[0][1][0];
        await handleMessage(msgId, fields);
        continue;
      }

      const claimed = await redis.xautoclaim(
        STREAM, GROUP, CONSUMER, CLAIM_IDLE_MS, '0-0', 'COUNT', 1
      );
      if (claimed && claimed[1] && claimed[1].length > 0) {
        const [msgId, fields] = claimed[1][0];
        if (fields) await handleMessage(msgId, fields);
      }
    } catch (err) {
      console.error(`[worker-redis] Error: ${err.message}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

run().catch((err) => {
  console.error('[worker-redis] Fatal:', err);
  process.exit(1);
});