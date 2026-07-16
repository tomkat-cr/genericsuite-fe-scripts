output "bucket_name" {
  description = "Frontend S3 bucket name"
  value       = module.frontend_hosting.bucket_name
}

output "distribution_id" {
  description = "CloudFront distribution ID"
  value       = module.frontend_hosting.distribution_id
}

output "distribution_domain_name" {
  description = "CloudFront domain name"
  value       = module.frontend_hosting.distribution_domain_name
}

output "website_url" {
  description = "Public URL"
  value       = module.frontend_hosting.website_url
}
