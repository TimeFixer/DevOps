const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3');
const { SQSClient, SendMessageCommand, GetQueueAttributesCommand } = require('@aws-sdk/client-sqs');

// Внутри Docker-сети всегда используем имя хоста контейнера (floci)
const ENDPOINT = process.env.AWS_ENDPOINT_URL || 'http://floci:4566';
const REGION = process.env.AWS_REGION || 'us-east-1';
const BUCKET_NAME = process.env.S3_BUCKET_NAME || 'quotes-bucket-local';
const OBJECT_KEY = process.env.S3_OBJECT_KEY || 'result.json';

const RAW_QUEUE_URL = process.env.SQS_QUEUE_URL || `${ENDPOINT}/000000000000/quotes-tasks-queue`;
// Если в урле из Terraform вдруг попался localhost, принудительно меняем на floci для сети Docker
const QUEUE_URL = RAW_QUEUE_URL.replace('localhost:4566', 'floci:4566');

const awsConfig = {
  region: REGION,
  endpoint: ENDPOINT,
  credentials: { accessKeyId: 'test', secretAccessKey: 'test' },
};

const s3 = new S3Client({ ...awsConfig, forcePathStyle: true });
const sqs = new SQSClient(awsConfig);

(async () => {
  const payload = JSON.stringify({ task: 'scrape-quotes', url: 'https://quotes.toscrape.com/scroll' });
  const sendRes = await sqs.send(new SendMessageCommand({ QueueUrl: QUEUE_URL, MessageBody: payload }));
  console.log(`[run] Задание отправлено в SQS (MessageId: ${sendRes.MessageId})`);

  const start = Date.now();
  while (Date.now() - start < 90000) {
    await new Promise(r => setTimeout(r, 2000));
    try {
      const s3Res = await s3.send(new GetObjectCommand({ Bucket: BUCKET_NAME, Key: OBJECT_KEY }));
      const quotes = JSON.parse(await s3Res.Body.transformToString());
      const sqsAttr = await sqs.send(new GetQueueAttributesCommand({ QueueUrl: QUEUE_URL, AttributeNames: ['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible'] }));
      const visible = Number(sqsAttr.Attributes?.ApproximateNumberOfMessages || 0);
      const inFlight = Number(sqsAttr.Attributes?.ApproximateNumberOfMessagesNotVisible || 0);

      if (Array.isArray(quotes) && quotes.length > 0 && visible === 0 && inFlight === 0) {
        console.log(`[run] Успех! В S3 сохранен валидный JSON (${quotes.length} цитат). Очередь пуста.`);
        process.exit(0);
      }
    } catch (_) {}
  }
  console.error('[run] Таймаут ожидания результата.');
  process.exit(1);
})();