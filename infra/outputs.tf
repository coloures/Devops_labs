output "bucket_name" {
  description = "Name of the S3 bucket with scraper results."
  value       = aws_s3_bucket.results.bucket
}

output "queue_name" {
  description = "Name of the SQS queue with scraping jobs."
  value       = aws_sqs_queue.jobs.name
}

output "queue_url" {
  description = "URL of the SQS queue."
  value       = aws_sqs_queue.jobs.url
}

output "aws_endpoint_url" {
  description = "Endpoint of the local AWS emulator."
  value       = var.aws_endpoint_url
}
