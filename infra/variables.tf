variable "aws_region" {
  description = "AWS region used by the provider and the emulator."
  type        = string
  default     = "us-east-1"
}

variable "aws_endpoint_url" {
  description = "Endpoint of the local AWS emulator (Floci)."
  type        = string
  default     = "http://localhost:4566"
}

variable "aws_access_key" {
  description = "Access key for the emulator. Floci accepts any non-empty value."
  type        = string
  default     = "test"
}

variable "aws_secret_key" {
  description = "Secret key for the emulator. Floci accepts any non-empty value."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "bucket_name" {
  description = "S3 bucket where scraper results are stored."
  type        = string
  default     = "quotes-results"
}

variable "queue_name" {
  description = "SQS queue with scraping jobs."
  type        = string
  default     = "quotes-jobs"
}
