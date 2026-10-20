resource "aws_s3_bucket" "results" {
  bucket = var.bucket_name

  # destroy должен удалять bucket вместе с накопленными результатами.
  force_destroy = true
}

resource "aws_sqs_queue" "jobs" {
  name = var.queue_name

  # Скрапер может работать дольше стандартных 30 секунд, поэтому сообщение
  # не должно становиться видимым другим воркерам во время обработки.
  visibility_timeout_seconds = 180
  message_retention_seconds  = 86400
}
