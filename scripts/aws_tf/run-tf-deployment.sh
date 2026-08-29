#!/bin/bash
# scripts/aws_tf/run-tf-deployment.sh
# Generic OpenTofu deployment wrapper for GenericSuite frontend stacks.
# OpenTofu counterpart of scripts/aws_deploy_to_s3.sh.
# 2026-07-16 | CR [GS-334]
#
# Usage:
#   bash scripts/aws_tf/run-tf-deployment.sh ACTION STAGE STACK [EXTRA_TOFU_ARGS...]
#
# Parameters:
#   ACTION: init | validate | plan | apply | destroy | output
#   STAGE:  dev | qa | staging | demo | prod
#   STACK:  directory name under scripts/aws_tf/stacks (frontend)
#
# Environment:
#   CICD_MODE=1        -> non-interactive (-auto-approve on apply/destroy)
#   TF_STATE_BUCKET    -> override state bucket name
set -euo pipefail

REPO_BASEDIR="$(pwd)"
SCRIPTS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

ACTION="${1:-}"
STAGE="${2:-}"
STACK="${3:-}"
if [ $# -ge 3 ]; then shift 3; else shift $#; fi

usage_abort() {
    echo "ERROR: $1"
    echo "Usage: $0 ACTION STAGE STACK [EXTRA_TOFU_ARGS...]"
    echo "  ACTION: init | validate | plan | apply | destroy | output"
    echo "  STAGE:  dev | qa | staging | demo | prod"
    echo "  STACK:  one of: $(ls "${SCRIPTS_DIR}/stacks" | tr '\n' ' ')"
    exit 1
}

if [ "${ACTION:-}" = "" ]; then usage_abort "ACTION is not set"; fi
if [ "${STAGE:-}" = "" ]; then usage_abort "STAGE is not set"; fi
if [ "${STACK:-}" = "" ]; then usage_abort "STACK is not set"; fi
if [ ! -d "${SCRIPTS_DIR}/stacks/${STACK}" ]; then usage_abort "Unknown STACK '${STACK}'"; fi
case "${ACTION}" in
    init|validate|plan|apply|destroy|output) ;;
    *) usage_abort "Unknown ACTION '${ACTION}'" ;;
esac

case "${STAGE}" in
    dev|qa|staging|demo|prod) ;;
    *) usage_abort "Unknown STAGE '${STAGE}'" ;;
esac

CICD_MODE="${CICD_MODE:-0}"

# Load the consuming app's .env
if [ -f "${REPO_BASEDIR}/.env" ]; then
    set -o allexport
    # shellcheck disable=SC1091
    . "${REPO_BASEDIR}/.env"
    set +o allexport
else
    echo "WARNING: no .env file in ${REPO_BASEDIR}"
fi

: "${APP_NAME:?ERROR: APP_NAME is not set}"
: "${AWS_REGION:?ERROR: AWS_REGION is not set}"

STAGE_UPPERCASE="$(echo "${STAGE}" | tr '[:lower:]' '[:upper:]')"
APP_NAME_LOWERCASE="$(echo "${APP_NAME}" | tr '[:upper:]' '[:lower:]')"

if [ "${AWS_ACCOUNT_ID:-}" = "" ]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --output json --no-paginate 2>/dev/null | jq -r '.Account' || true)"
fi
if [ "${AWS_ACCOUNT_ID:-}" = "" ] || [ "${AWS_ACCOUNT_ID}" = "null" ]; then
    echo "ERROR: AWS_ACCOUNT_ID could not be retrieved. Configure AWS credentials."
    exit 1
fi

TF_STATE_BUCKET="${TF_STATE_BUCKET:-${APP_NAME_LOWERCASE}-tf-state-${AWS_ACCOUNT_ID}}"
bash "${SCRIPTS_DIR}/bootstrap-tf-state.sh" "${TF_STATE_BUCKET}" "${AWS_REGION}"

# Common TF_VARs (every stack declares only the ones it needs)
export TF_VAR_app_name="${APP_NAME_LOWERCASE}"
export TF_VAR_stage="${STAGE}"
export TF_VAR_aws_region="${AWS_REGION}"
export TF_VAR_aws_account_id="${AWS_ACCOUNT_ID}"

# Frontend variable type (FE by default; e.g. WS for a second frontend)
VARIABLE_TYPE="$(echo "${VARIABLE_TYPE:-FE}" | tr '[:lower:]' '[:upper:]')"
varname_bucket="AWS_S3_BUCKET_NAME_${VARIABLE_TYPE}"
FE_BUCKET_NAME="${!varname_bucket:-}"
# Replace [STAGE] token if present (parity with set_fe_cloudfront_domain.sh)
FE_BUCKET_NAME="$(echo "${FE_BUCKET_NAME}" | perl -pe "s/\[STAGE\]/${STAGE}/g")"
export TF_VAR_bucket_name="${FE_BUCKET_NAME}"

varname_app_url="APP_${VARIABLE_TYPE}_URL"
APP_URL_RAW="${!varname_app_url:-}"
APP_URL_CLEANED="$(echo "${APP_URL_RAW}" | perl -pe 's|^https?://||i; s|[:/].*||; s|\s+||g')"
export TF_VAR_app_url="${APP_URL_CLEANED}"

varname_cert="AWS_SSL_CERTIFICATE_ARN_${VARIABLE_TYPE}"
TF_VAR_acm_certificate_arn="${!varname_cert:-}"
if [ "${TF_VAR_acm_certificate_arn:-}" = "" ]; then
    TF_VAR_acm_certificate_arn="${AWS_SSL_CERTIFICATE_ARN:-}"
fi
export TF_VAR_acm_certificate_arn

export TF_VAR_tf_state_bucket="${TF_STATE_BUCKET}"

# Optional per-stack variable builder (e.g. secrets maps, dynamodb tables)
if [ -f "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPTS_DIR}/stacks/${STACK}/build-tfvars.sh"
fi

cd "${SCRIPTS_DIR}/stacks/${STACK}"

echo ""
echo "RUN-TF-DEPLOYMENT | action=${ACTION} stage=${STAGE} stack=${STACK}"
echo "State: s3://${TF_STATE_BUCKET}/${STAGE}/${STACK}.tfstate"
echo ""

tofu init -reconfigure -input=false \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=${STAGE}/${STACK}.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"

APPROVE_ARG=""
if [ "${CICD_MODE}" = "1" ]; then
    APPROVE_ARG="-auto-approve"
fi

case "${ACTION}" in
    init)
        ;;
    validate)
        tofu validate "$@"
        ;;
    plan)
        tofu plan -input=false "$@"
        ;;
    apply)
        # shellcheck disable=SC2086
        tofu apply -input=false ${APPROVE_ARG} "$@"
        ;;
    destroy)
        # shellcheck disable=SC2086
        tofu destroy -input=false ${APPROVE_ARG} "$@"
        ;;
    output)
        tofu output "$@"
        ;;
esac

echo ""
echo "Done with '${ACTION}' over stack '${STACK}' (stage '${STAGE}')"
cd "${REPO_BASEDIR}"
