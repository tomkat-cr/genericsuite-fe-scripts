variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "bucket_name" {
  description = "Frontend S3 bucket name (resolved by wrapper)"
  type        = string
}

variable "app_url" {
  description = "Frontend FQDN (cleaned, no protocol); empty disables custom domain"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN; empty tries lookup by app_url"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 zone ID; empty skips DNS records"
  type        = string
  default     = ""
}
