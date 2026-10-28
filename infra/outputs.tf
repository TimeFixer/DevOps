output "bucket_name" {
  value = aws_s3_bucket.results.bucket
}

output "queue_url" {
  value = aws_sqs_queue.tasks.url
}