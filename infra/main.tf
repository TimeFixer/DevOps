resource "aws_s3_bucket" "results" {
  bucket = var.bucket_name
  force_destroy = true

  tags = {
    Environment = var.environment
    Project     = "quotes-scraper"
  }
}

resource "aws_sqs_queue" "tasks" {
  name                       = var.queue_name
  visibility_timeout_seconds = 120

  tags = {
    Environment = var.environment
    Project     = "quotes-scraper"
  }
}