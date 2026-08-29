#!/bin/bash
# File: scripts/aws_get_ssl_cert_arn.sh
# 2024-04-01 | CR

set -euo pipefail

get_ssl_cert_arn() {
    local domain_varname=$1
    local domain=$2

    echo ""
    echo "domain_varname: '${domain_varname}'"
    echo "domain: '${domain}'"

    echo ""
    echo "NOTE: These 3 warnings '-i used with no filenames on the command line, reading from STDIN.' are normal..."
    local domain_cleaned=$(echo $domain | perl -i -pe 's|https:\/\/||' | perl -i -pe 's|http:\/\/||' | perl -i -pe 's|:.*||')

    echo ""
    echo "Fetching ACM Certificate ARN for '${domain_cleaned}'..."
    echo "(Originally: '${domain})"
    # AWS_SSL_CERTIFICATE_ARN=$(aws acm list-certificates --region ${AWS_REGION} --output text --query "CertificateSummaryList[?DomainName=='${APP_FE_URL}'].CertificateArn | [0]")
    AWS_SSL_CERTIFICATE_ARN=$(aws acm list-certificates --output text --query "CertificateSummaryList[?DomainName=='${domain_cleaned}'].CertificateArn | [0]")

    echo ""
    echo "[${domain_cleaned}] ACM Certificate ARN: ${AWS_SSL_CERTIFICATE_ARN}"

    if [[ "${AWS_SSL_CERTIFICATE_ARN}" = "" || "${AWS_SSL_CERTIFICATE_ARN}" = "None" || "${AWS_SSL_CERTIFICATE_ARN}" = "null" || "${AWS_SSL_CERTIFICATE_ARN}" = "NULL" || "${AWS_SSL_CERTIFICATE_ARN}" = "Null" ]]; then
        AWS_SSL_CERTIFICATE_ARN=""
        echo "ERROR: ACM Certificate ARN not found for '${domain_cleaned}'"
    fi
}

REPO_BASEDIR="`pwd`"
cd "`dirname "$0"`" ;
SCRIPTS_DIR="`pwd`" ;
cd "${REPO_BASEDIR}"

UPDATE_BUILD="1"

ENV_FILESPEC=""
if [ -f "${REPO_BASEDIR}/.env" ]; then
    ENV_FILESPEC="${REPO_BASEDIR}/.env"
else
    ERROR_MSG="ERROR .env file doesn't exist"
fi
if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${ENV_FILESPEC:-}" != "" ]; then
        set -o allexport; source ${ENV_FILESPEC}; set +o allexport ;
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    # Default variable type is "FE"
    VARIABLE_TYPE="FE"
    if [ "${1:-}" != "" ];then
        # If a parameter is provided, use it as the variable type. E.g. "BE" or "WS"
        VARIABLE_TYPE=$(echo $1 | tr '[:lower:]' '[:upper:]')
    fi
    echo "VARIABLE_TYPE: ${VARIABLE_TYPE}"

    # domain="${APP_FE_URL}"
    varname_app_url="APP_${VARIABLE_TYPE}_URL"
    domain="${!varname_app_url:-}"
    get_ssl_cert_arn "APP_${VARIABLE_TYPE}_URL" "${domain}"

    domain="${REACT_APP_API_URL}"
    get_ssl_cert_arn "REACT_APP_API_URL" ${domain}
fi

echo ""
if [ "${ERROR_MSG:-}" = "" ]; then
    echo "Done..."
else
    echo "ERROR: ${ERROR_MSG}"
fi
echo ""
