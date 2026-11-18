variable "aws_region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "Имя корзины S3"
  default     = "quotes-bucket-local"
}

variable "queue_name" {
  type        = string
  description = "Имя очереди SQS"
  default     = "quotes-tasks-queue"
}

variable "environment" {
  type        = string
  description = "Окружение (dev, stage, prod)"
  default     = "dev"
}