provider "aws" {
  region = var.aws_region

  access_key = var.aws_access_key
  secret_key = var.aws_secret_key

  # Floci не выдаёт реальные STS-токены и не требует валидации аккаунта.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  # Floci обслуживает S3 по path-style URL: http://host:4566/<bucket>/<key>.
  s3_use_path_style = true

  endpoints {
    s3  = var.aws_endpoint_url
    sqs = var.aws_endpoint_url
  }
}
