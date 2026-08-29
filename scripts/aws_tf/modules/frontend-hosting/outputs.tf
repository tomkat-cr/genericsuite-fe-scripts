output "bucket_name" {
  description = "Frontend S3 bucket name"
  value       = aws_s3_bucket.this.bucket
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "CloudFront domain name (dxxxx.cloudfront.net)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "website_url" {
  description = "Public URL"
  value       = length(var.aliases) > 0 ? "https://${var.aliases[0]}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}
