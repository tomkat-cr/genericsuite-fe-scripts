module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  bucket_name         = var.bucket_name
  app_name            = var.app_name
  stage               = var.stage
  aliases             = var.app_url != "" ? [var.app_url] : []
  acm_certificate_arn = var.acm_certificate_arn
  hosted_zone_id      = var.hosted_zone_id
}
