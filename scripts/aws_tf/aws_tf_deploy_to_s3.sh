#!/bin/bash
# scripts/aws_tf/aws_tf_deploy_to_s3.sh
# OpenTofu-based frontend deployment: infra via tofu, app build + S3 sync +
# CloudFront invalidation in bash. OpenTofu counterpart of
# scripts/aws_deploy_to_s3.sh (which remains untouched).
# 2026-07-16 | CR [GS-334]
#
# Usage:
#   bash node_modules/genericsuite-fe-scripts/scripts/aws_tf/aws_tf_deploy_to_s3.sh STAGE [VARIABLE_TYPE]
#   STAGE: dev | qa | staging | demo | prod
#   VARIABLE_TYPE: FE (default) or another frontend variable prefix
set -euo pipefail

REPO_BASEDIR="$(pwd)"
SCRIPTS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
FE_SCRIPTS_DIR="$(cd -- "${SCRIPTS_DIR}/.." >/dev/null 2>&1 && pwd -P)"

STAGE="${1:-}"
VARIABLE_TYPE="$(echo "${2:-FE}" | tr '[:lower:]' '[:upper:]')"
export VARIABLE_TYPE

if [ "${STAGE:-}" = "" ]; then
    echo "Usage: $0 STAGE [VARIABLE_TYPE]"
    exit 1
fi

if [ ! -f "${REPO_BASEDIR}/.env" ]; then
    echo "ERROR: .env file doesn't exist"
    exit 1
fi
set -o allexport
# shellcheck disable=SC1091
. "${REPO_BASEDIR}/.env"
set +o allexport

RUN_BUNDLER="${RUN_BUNDLER:-vite}"
UPDATE_BUILD="${UPDATE_BUILD:-1}"
BUILD_DIR="${BUILD_DIR:-build}"
REACT_APP_VERSION="$(cat "${REPO_BASEDIR}/version.txt")"
export REACT_APP_VERSION

# 1) Infrastructure: S3 bucket + CloudFront (OAC) via OpenTofu
bash "${SCRIPTS_DIR}/run-tf-deployment.sh" apply "${STAGE}" frontend

# 2) Read infra outputs
cd "${SCRIPTS_DIR}/stacks/frontend"
BUCKET_NAME="$(tofu output -raw bucket_name)"
DIST_ID="$(tofu output -raw distribution_id)"
DOMAIN_NAME="$(tofu output -raw distribution_domain_name)"
cd "${REPO_BASEDIR}"
echo ""
echo "Bucket: ${BUCKET_NAME} | CloudFront: ${DIST_ID} (${DOMAIN_NAME})"

# 3) Build the app (same flow as aws_deploy_to_s3.sh)
if [ "${RUN_BUNDLER}" != "none" ] && [ "${UPDATE_BUILD}" = "1" ]; then
    bash "${FE_SCRIPTS_DIR}/run_method_dependency_manager.sh" install "${RUN_BUNDLER}"

    TSCONFIG_BASE_URL="$(perl -ne 'print $1 if /"baseUrl":\s*"([^"]*)"/' tsconfig.json)"
    PREV_HOME_PAGE="$(perl -ne 'print $1 if /"homepage":\s*"([^"]*)"/' package.json)"

    # Restore package.json / tsconfig.json even if the build below fails
    restore_pkg_files() {
        if [ "${PREV_HOME_PAGE:-}" != "" ]; then
            perl -i -pe "s|\"homepage\":.*|\"homepage\": \"${PREV_HOME_PAGE}\",|g" package.json || true
        fi
        perl -i -pe 's|"type1": "module"|"type": "module"|g' package.json || true
        if [ "${TSCONFIG_BASE_URL:-}" = "./src/lib" ]; then
            perl -i -pe 's|"baseUrl": "./src"|"baseUrl": "./src/lib"|g' tsconfig.json || true
        fi
    }
    trap restore_pkg_files EXIT

    if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
        perl -i -pe 's|"baseUrl": "./src/lib"|"baseUrl": "./src"|g' tsconfig.json
    fi

    perl -i -pe "s|\"homepage\":.*|\"homepage\": \"https://${DOMAIN_NAME}\",|g" package.json

    if [ "${PRESERVE_MODULE_TYPE:-0}" != "1" ]; then
        perl -i -pe 's|"type": "module"|"type1": "module"|g' package.json
    fi

    bash "${FE_SCRIPTS_DIR}/run_symlinks_handler.sh" remove

    echo "Building React app... (${RUN_BUNDLER})"
    if [ "${RUN_BUNDLER}" = "webpack" ]; then
        if [ "${STAGE}" = "prod" ]; then
            npx webpack --mode production
        else
            npx webpack --mode development
        fi
    elif [ "${RUN_BUNDLER}" = "vite" ]; then
        npx vite build
    else
        npx react-app-rewired build
    fi

    # shellcheck disable=SC1091
    source "${FE_SCRIPTS_DIR}/build_copy_images.sh" "" ""
fi

# 4) Sync to S3 (no ACLs: bucket is private, served through OAC)
echo "Deploying to AWS S3..."
aws s3 sync "${BUILD_DIR}" "s3://${BUCKET_NAME}" --delete --region "${AWS_REGION}"

# 5) Invalidate CloudFront cache
echo "Invalidating CloudFront cache..."
aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths "/*"

echo ""
echo "Deployment complete: https://${DOMAIN_NAME}"
