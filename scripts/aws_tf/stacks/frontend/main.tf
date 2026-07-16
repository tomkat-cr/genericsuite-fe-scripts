data "aws_acm_certificate" "lookup" {
  count    = var.app_url != "" && var.acm_certificate_arn == "" ? 1 : 0
  provider = aws.us_east_1
  domain   = var.app_url
  statuses = ["ISSUED"]
}

locals {
  resolved_certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (
    length(data.aws_acm_certificate.lookup) > 0 ? data.aws_acm_certificate.lookup[0].arn : ""
  )
}

module "frontend_hosting" {
  source = "../../modules/frontend-hosting"

  bucket_name         = var.bucket_name
  app_name            = var.app_name
  stage               = var.stage
  aliases             = var.app_url != "" ? [var.app_url] : []
  acm_certificate_arn = local.resolved_certificate_arn
  hosted_zone_id      = var.hosted_zone_id
}
