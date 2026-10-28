const { execFile } = require('child_process');
const { promisify } = require('util');
const fs = require('fs').promises;
const path = require('path');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} = require('@aws-sdk/client-sqs');

const execFileAsync = promisify(execFile);

const ENDPOINT = process.env.AWS_ENDPOINT_URL || 'http://floci:4566';
const REGION = process.env.AWS_REGION || 'us-east-1';
const BUCKET_NAME = process.env.S3_BUCKET_NAME || 'quotes-bucket-local';
const RAW_QUEUE_URL =
  process.env.SQS_QUEUE_URL ||
  `${ENDPOINT}/000000000000/quotes-tasks-queue`;

// Заменяем localhost на адрес контейнера floci, если URL пришёл из terraform output
const QUEUE_URL = RAW_QUEUE_URL.replace('http://localhost:4566', ENDPOINT);

const awsConfig = {
  region: REGION,
  endpoint: ENDPOINT,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID || 'test',
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'test',
  },
};

const s3 = new S3Client({ ...awsConfig, forcePathStyle: true });
const sqs = new SQSClient(awsConfig);

async function processMessage(message) {
  console.log(`[worker] Получено задание из SQS (MessageId: ${message.MessageId})`);

  // 1. Запускаем оригинальный скрапер без изменений
  const scraperPath = path.join(__dirname, 'index.js');
  const { stdout, stderr } = await execFileAsync('node', [scraperPath]);
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);

  // 2. Читаем и валидируем результат работы скрапера
  const resultPath = path.join(__dirname, '..', 'out', 'result.json');
  const rawData = await fs.readFile(resultPath, 'utf-8');
  const parsed = JSON.parse(rawData);

  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error('Результирующий JSON пуст или некорректен');
  }

  // 3. Сохраняем JSON в S3
  const objectKey = process.env.S3_OBJECT_KEY || 'result.json';
  await s3.send(
    new PutObjectCommand({
      Bucket: BUCKET_NAME,
      Key: objectKey,
      Body: rawData,
      ContentType: 'application/json',
    })
  );
  console.log(`[worker] Файл ${objectKey} (${parsed.length} цитат) успешно записан в S3 бакет ${BUCKET_NAME}`);

  // 4. Удаляем сообщение из очереди ТОЛЬКО после успешной записи в S3
  await sqs.send(
    new DeleteMessageCommand({
      QueueUrl: QUEUE_URL,
      ReceiptHandle: message.ReceiptHandle,
    })
  );
  console.log(`[worker] Сообщение ${message.MessageId} удалено из очереди SQS`);
}

async function pollQueue() {
  console.log(`[worker] Ожидание заданий из очереди: ${QUEUE_URL}`);
  while (true) {
    try {
      const response = await sqs.send(
        new ReceiveMessageCommand({
          QueueUrl: QUEUE_URL,
          MaxNumberOfMessages: 1,
          WaitTimeSeconds: 5,
        })
      );

      if (response.Messages && response.Messages.length > 0) {
        for (const msg of response.Messages) {
          await processMessage(msg);
        }
      }
    } catch (error) {
      console.error('[worker] Ошибка при обработке сообщения:', error.message);
      await new Promise((resolve) => setTimeout(resolve, 3000));
    }
  }
}

pollQueue();

