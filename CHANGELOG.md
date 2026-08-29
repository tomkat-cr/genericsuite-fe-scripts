# CHANGELOG

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](http://semver.org/) and [Keep a Changelog](http://keepachangelog.com/).


## [Unreleased] - YYYY-MM-DD

### Added

### Changed

### Fixed

### Removed

### Security


## [1.0.0] - 2026-08-30

### Added
- Create the frontend scripts library [GS-107].
- AGENTS.md, GEMINI.md, and CLAUDE.md files to provide context and instructions to AI Coding Assistants [GS-303].
- OpenTofu (Terraform-compatible) IaC frontend deployment in `scripts/aws_tf`: `frontend-hosting` module (private S3 + CloudFront with Origin Access Control, redirect-to-https, TLSv1.2_2021, SPA error routing) and `aws_tf_deploy_to_s3.sh` full pipeline (tofu apply + build + S3 sync + CloudFront invalidation), with S3 remote state — parallel to the existing `aws_deploy_to_s3.sh`, which remains unchanged [GS-334].

### Changed
- Change FE S3 deployment to be used on Landing Pages [GS-328].
- Rename AWS_S3_BUCKET_NAME to AWS_S3_BUCKET_NAME_FE in the .env file and scripts [GS-328].
- Enhance `aws_deploy_to_s3.sh`: Set default values for RUN_BUNDLER, UPDATE_BUILD, and BUILD_DIR if not specified via CLI. Improve bucket name handling and CloudFront distribution checks. Update package.json homepage during deployment and restore after completion only if RUN_BUNDLER != none. Use BUILD_DIR to set the build directory, so mobile deployment -that's not react-vite- can be done.

### Security
- Bump Node.js version in .nvmrc to 26 [GS-339].
