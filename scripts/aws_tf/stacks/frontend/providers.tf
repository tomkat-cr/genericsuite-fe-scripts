provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      App       = var.app_name
      Stage     = var.stage
      ManagedBy = "opentofu"
      Ticket    = "GS-334"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      App       = var.app_name
      Stage     = var.stage
      ManagedBy = "opentofu"
      Ticket    = "GS-334"
    }
  }
}
