variable "bucket_name" {
  description = "Frontend S3 bucket name"
  type        = string
}

variable "app_name" {
  description = "Application name (lowercase)"
  type        = string
}

variable "stage" {
  description = "Deployment stage"
  type        = string
}

variable "aliases" {
  description = "CloudFront aliases (frontend FQDNs); empty list disables custom domain"
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "Resolved ACM certificate ARN (us-east-1), passed in by the caller; empty disables custom viewer certificate"
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 zone ID for alias records; empty skips DNS"
  type        = string
  default     = ""
}
