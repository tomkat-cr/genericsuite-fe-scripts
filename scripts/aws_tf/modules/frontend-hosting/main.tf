locals {
  use_aliases = length(var.aliases) > 0
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_acm_certificate" "lookup" {
  count    = local.use_aliases && var.acm_certificate_arn == "" ? 1 : 0
  provider = aws.us_east_1
  domain   = var.aliases[0]
  statuses = ["ISSUED"]
}

locals {
  certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (
    local.use_aliases ? data.aws_acm_certificate.lookup[0].arn : ""
  )
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  comment             = "CloudFront Distribution for '${var.bucket_name}'"
  enabled             = true
  default_root_object = "index.html"
  aliases             = var.aliases

  origin {
    origin_id                = aws_s3_bucket.this.bucket_regional_domain_name
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = aws_s3_bucket.this.bucket_regional_domain_name
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    min_ttl                = 0

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # SPA routing: send S3 403/404 to index.html
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.certificate_arn == "" ? true : null
    acm_certificate_arn            = local.certificate_arn != "" ? local.certificate_arn : null
    ssl_support_method             = local.certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = local.certificate_arn != "" ? "TLSv1.2_2021" : null
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "AllowCloudFrontOACAccess"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_route53_record" "alias" {
  for_each = var.hosted_zone_id != "" ? toset(var.aliases) : toset([])

  zone_id         = var.hosted_zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
