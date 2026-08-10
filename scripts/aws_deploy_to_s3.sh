#!/bin/bash
# File: scripts/aws_deploy_to_s3.sh
# 2023-07-17 | CR

set -euo pipefail

continue_or_stop() {
    echo "Type 'y' and press Enter to continue, any other value to cancel..."
    read var < /dev/tty
    echo ""
    if [[ "$var" = "Y" || "$var" = "y" ]]; then
        echo "Continuing..."
        ERROR_MSG=""
    else
        echo "Exiting..."
    fi
    echo ""
}

rename_module_type() {
    perl -i -pe"s|\"type\": \"module\"|\"type1\": \"module\"|g" package.json
}

restore_module_type() {
    perl -i -pe"s|\"type1\": \"module\"|\"type\": \"module\"|g" package.json
}

clean_domain_name() {
    echo "$1" | perl -pe 's|^https?://||i; s|[:/].*||; s|\s+||g'
}

get_ssl_cert_arn() {
    echo ""
    domain_cleaned=$(clean_domain_name "${domain}")

    echo ""
    echo "Fetching ACM Certificate ARN for '${domain_cleaned}'..."
    echo "(Originally: '${domain})"

    varname_cert="AWS_SSL_CERTIFICATE_ARN_${VARIABLE_TYPE}"
    AWS_SSL_CERTIFICATE_ARN_BY_TYPE="${!varname_cert:-}"
    if [ "${AWS_SSL_CERTIFICATE_ARN_BY_TYPE:-}" != "" ];then
        AWS_SSL_CERTIFICATE_ARN="${AWS_SSL_CERTIFICATE_ARN_BY_TYPE}"
        echo "Using AWS_SSL_CERTIFICATE_ARN_${VARIABLE_TYPE}..."
    fi

    if [ "${AWS_SSL_CERTIFICATE_ARN:-}" = "" ];then
        # AWS_SSL_CERTIFICATE_ARN=$(aws acm list-certificates --region ${AWS_REGION} --output text --query "CertificateSummaryList[?DomainName=='${APP_URL}'].CertificateArn | [0]")
        AWS_SSL_CERTIFICATE_ARN=$(aws acm list-certificates --output text --query "CertificateSummaryList[?DomainName=='${domain_cleaned}'].CertificateArn | [0]")
    fi
    echo ""
    echo "[${domain_cleaned}] ACM Certificate ARN: ${AWS_SSL_CERTIFICATE_ARN}"

    if [[ "${AWS_SSL_CERTIFICATE_ARN}" = "" || "${AWS_SSL_CERTIFICATE_ARN}" = "None" || "${AWS_SSL_CERTIFICATE_ARN}" = "null" || "${AWS_SSL_CERTIFICATE_ARN}" = "NULL" || "${AWS_SSL_CERTIFICATE_ARN}" = "Null" ]]; then
        AWS_SSL_CERTIFICATE_ARN=""
        echo "ERROR: ACM Certificate ARN not found for '${domain_cleaned}'"
    fi
}

# Empty / sentinel values from aws --output text
is_blank_aws_value() {
    case "${1:-}" in
        ""|"None"|"none"|"null"|"NULL"|"Null") return 0 ;;
        *) return 1 ;;
    esac
}

# Create or reuse CloudFront Origin Access Control (OAC) for the S3 bucket.
# Matches scripts/aws_tf/modules/frontend-hosting (private bucket + OAC).
# Status messages go to stderr; stdout is only the OAC id.
ensure_cloudfront_oac() {
    local oac_name="${BUCKET_NAME}-oac"
    local oac_id
    oac_id=$(aws cloudfront list-origin-access-controls \
        --query "OriginAccessControlList.Items[?Name=='${oac_name}'].Id | [0]" \
        --output text 2>/dev/null || true)
    if is_blank_aws_value "${oac_id}"; then
        echo "Creating CloudFront Origin Access Control '${oac_name}'..." >&2
        oac_id=$(aws cloudfront create-origin-access-control \
            --origin-access-control-config "Name=${oac_name},Description=OAC for ${BUCKET_NAME},OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4" \
            --query 'OriginAccessControl.Id' \
            --output text)
    else
        echo "Reusing CloudFront Origin Access Control '${oac_name}' (${oac_id})" >&2
    fi
    if is_blank_aws_value "${oac_id}"; then
        return 1
    fi
    printf '%s\n' "${oac_id}"
}

# Attach OAC to the distribution's first S3 origin and SPA 403/404 → index.html.
# Previous OAI "association" only verified the identity existed and never updated
# the distribution, which caused AccessDenied after public bucket access was removed.
attach_oac_to_distribution() {
    local dist_id="$1"
    local oac_id="$2"
    local tmp_dir etag current_oac

    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp_dir}'" RETURN

    aws cloudfront get-distribution-config --id "${dist_id}" --output json > "${tmp_dir}/dist.json"
    etag=$(jq -r '.ETag' "${tmp_dir}/dist.json")
    current_oac=$(jq -r '.DistributionConfig.Origins.Items[0].OriginAccessControlId // empty' "${tmp_dir}/dist.json")

    if [ "${current_oac}" = "${oac_id}" ]; then
        local has_spa_errors
        has_spa_errors=$(jq -r '
            [.DistributionConfig.CustomErrorResponses.Items[]? | select(.ErrorCode == 403 or .ErrorCode == 404)]
            | length
        ' "${tmp_dir}/dist.json")
        if [ "${has_spa_errors}" = "2" ]; then
            echo "Distribution ${dist_id} already uses OAC ${oac_id} with SPA error responses"
            return 0
        fi
    fi

    echo "Updating CloudFront distribution ${dist_id} to use OAC ${oac_id}..."
    # Strip nulls: get-distribution-config → update-distribution rejects null optional fields.
    jq --arg oac_id "${oac_id}" '
      .DistributionConfig
      | .Origins.Items[0].OriginAccessControlId = $oac_id
      | .Origins.Items[0].S3OriginConfig = {"OriginAccessIdentity": ""}
      | del(.Origins.Items[0].CustomOriginConfig)
      | .CustomErrorResponses = {
          "Quantity": 2,
          "Items": [
            {
              "ErrorCode": 403,
              "ResponsePagePath": "/index.html",
              "ResponseCode": "200",
              "ErrorCachingMinTTL": 0
            },
            {
              "ErrorCode": 404,
              "ResponsePagePath": "/index.html",
              "ResponseCode": "200",
              "ErrorCachingMinTTL": 0
            }
          ]
        }
      | walk(if type == "object" then with_entries(select(.value != null)) else . end)
    ' "${tmp_dir}/dist.json" > "${tmp_dir}/update.json"

    if ! aws cloudfront update-distribution \
        --id "${dist_id}" \
        --if-match "${etag}" \
        --distribution-config "file://${tmp_dir}/update.json" \
        --output text > /dev/null
    then
        return 1
    fi
    echo "CloudFront distribution ${dist_id} updated with OAC ${oac_id}"
}

remove_symlinks() {
    bash "${SCRIPTS_DIR}/run_symlinks_handler.sh" remove
}

REPO_BASEDIR="`pwd`"
SCRIPTS_DIR="$( cd -- "$(dirname "$BASH_SOURCE")" >/dev/null 2>&1 ; pwd -P )"
cd "${REPO_BASEDIR}"

# Defaults

if [ "${RUN_BUNDLER:-}" = "" ]; then
    echo "RUN_BUNDLER is not set, setting default to vite"
    RUN_BUNDLER="vite"
fi

if [ "${UPDATE_BUILD:-}" = "" ]; then
    echo "UPDATE_BUILD is not set, setting default to 1"
    UPDATE_BUILD="1"
fi

if [ "${BUILD_DIR:-}" = "" ]; then
    echo "BUILD_DIR is not set, setting default to build"
    BUILD_DIR="build"
fi

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

export REACT_APP_VERSION=`cat "version.txt"`

if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${2:-}" = "" ]; then
        VARIABLE_TYPE="FE" # Frontend default variable type
    else
        VARIABLE_TYPE=$(echo $2 | tr '[:lower:]' '[:upper:]')
    fi
    echo "VARIABLE_TYPE: ${VARIABLE_TYPE}"
fi


# Name of the S3 bucket
if [ "${ERROR_MSG:-}" = "" ]; then
    varname_bucket="AWS_S3_BUCKET_NAME_${VARIABLE_TYPE}"
    BUCKET_NAME="${!varname_bucket:-}"
    echo "BUCKET_NAME: ${BUCKET_NAME}"
    if [ "${BUCKET_NAME:-}" = "" ];then
        ERROR_MSG="AWS_S3_BUCKET_NAME_${VARIABLE_TYPE} is not set"
    fi
fi

# Region of the S3 bucket
if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${AWS_REGION:-}" = "" ];then
        ERROR_MSG="AWS_REGION is not set"
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    varname_app_url="APP_${VARIABLE_TYPE}_URL"
    APP_URL="${!varname_app_url:-}"
    APP_URL=$(clean_domain_name "${APP_URL}")
    echo "APP_URL: ${APP_URL}"
fi

# Frontend domain name
if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${APP_URL:-}" = "" ];then
        ERROR_MSG="APP_${VARIABLE_TYPE}_URL is not set (or invalid after removing protocol/path)"
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${AWS_PROFILE:-}" = "" ];then
        AWS_PROFILE="default"
    fi
    echo "Getting AWS account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output json --no-paginate --region "${AWS_REGION}" --profile "${AWS_PROFILE}" | jq -r '.Account')
    if [ "${AWS_ACCOUNT_ID:-}" = "" ];then
        ERROR_MSG="AWS_ACCOUNT_ID could not be retrieved"
    fi
fi

# Deploy to S3
if [ "${ERROR_MSG:-}" = "" ]; then
    echo "Verifying AWS S3 bucket $BUCKET_NAME existence..."
    if ! S3_BUCKET_NOT_FOUND=$(aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" 2>&1 | grep -c 'Not Found')
    then
        echo "WARNING: running aws s3api head-bucket --bucket ${BUCKET_NAME} --region ${AWS_REGION} returned non-zero exit code ($?). Continuing..."
    fi
    echo "S3_BUCKET_NOT_FOUND: ${S3_BUCKET_NOT_FOUND}"
    if [ "${S3_BUCKET_NOT_FOUND}" = "1" ];then

        echo "Creating the AWS S3 bucket $BUCKET_NAME..."
        # No --acl: buckets created after April 2023 default to Object Ownership
        # "Bucket owner enforced" (ACLs disabled); --acl would fail with AccessControlListNotSupported.
        if [ "${AWS_REGION}" = "us-east-1" ]; then
            if ! aws s3api create-bucket --bucket "$BUCKET_NAME" --region "${AWS_REGION}" --output text
            then
                ERROR_MSG="ERROR could not create the bucket [1] - Region: ${AWS_REGION}"
            fi
        else
            if ! aws s3api create-bucket --bucket "$BUCKET_NAME" --region "${AWS_REGION}" --create-bucket-configuration LocationConstraint="${AWS_REGION}" --output text
            then
                ERROR_MSG="ERROR could not create the bucket [2] - Region: ${AWS_REGION}"
            fi
        fi
        if [ "${ERROR_MSG:-}" = "" ]; then
            # Align with Terraform frontend-hosting module: private bucket, ACLs off.
            if ! aws s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' --region "${AWS_REGION}" --output text
            then
                echo "WARNING: could not put bucket ownership controls - Region: ${AWS_REGION}. Continuing..."
            fi
            if ! aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" --region "${AWS_REGION}" --output text
            then
                echo "WARNING: could not put public access block - Region: ${AWS_REGION}. Continuing..."
            fi
        fi
    else
        echo "AWS S3 bucket $BUCKET_NAME exists..."
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    echo "Creating/verifying the AWS Cloudfront distribution..."

    S3_ORIGIN_DOMAIN="${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
    S3_ORIGIN_DOMAIN_LEGACY="${BUCKET_NAME}.s3.amazonaws.com"

    # Get CloudFront distribution ID (regional or legacy S3 origin domain)
    echo "Getting CloudFront distribution ID..."
    DIST_ID=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Origins.Items[0].DomainName=='${S3_ORIGIN_DOMAIN}' || Origins.Items[0].DomainName=='${S3_ORIGIN_DOMAIN_LEGACY}'].Id | [0]" \
        --output text)
    if is_blank_aws_value "${DIST_ID}"; then
        DIST_ID=""
    fi
    echo "CloudFront Distribution ID: ${DIST_ID:-}"

    # Verify existence of CloudFront distribution ID
    echo "Verifying CloudFront distribution ID..."
    if [ "${DIST_ID:-}" != "" ]; then
        if aws cloudfront get-distribution --id "${DIST_ID}" --no-paginate > /dev/null 2>&1; then
            echo "CloudFront Distribution ${DIST_ID} exists"
        else
            echo "CloudFront Distribution ${DIST_ID} does not exist"
            DIST_ID=""
        fi
    fi

    # OAC must exist before create/update so CloudFront can sign requests to the private bucket
    if [ "${ERROR_MSG:-}" = "" ]; then
        if ! OAC_ID=$(ensure_cloudfront_oac); then
            ERROR_MSG="ERROR creating/finding CloudFront Origin Access Control for '${BUCKET_NAME}'"
        else
            echo "CloudFront OAC ID: ${OAC_ID}"
        fi
    fi

    # Creating CloudFront distribution
    if [ "${ERROR_MSG:-}" = "" ] && [ "${DIST_ID:-}" = "" ]; then
        echo ""
        echo "Fetching ACM Certificate ARN for ${APP_URL} to create the CloudFront distribution..."
        domain="${APP_URL}"
        get_ssl_cert_arn
   
        if [ "${AWS_SSL_CERTIFICATE_ARN:-}" = "" ]; then
            ERROR_MSG="ERROR: ACM Certificate ARN not found for ${domain}"

            echo ""
            echo "The ACM (SSL) Certificate ARN not found for ${domain}"
            echo "Do you want to proceed with no domain association? (y/N)"
            continue_or_stop
            if [ "${ERROR_MSG:-}" = "" ]; then
                echo "Proceeding with no domain association..."
                DIST_ID=$(aws cloudfront create-distribution \
                    --distribution-config "{
                        \"CallerReference\": \"${BUCKET_NAME}-distribution\",
                        \"Comment\": \"CloudFront Distribution for '${BUCKET_NAME}'\",
                        \"Enabled\": true,
                        \"DefaultRootObject\": \"index.html\",
                        \"Origins\": {
                            \"Quantity\": 1,
                            \"Items\": [
                                {
                                    \"Id\": \"${S3_ORIGIN_DOMAIN}\",
                                    \"DomainName\": \"${S3_ORIGIN_DOMAIN}\",
                                    \"OriginPath\": \"\",
                                    \"CustomHeaders\": { \"Quantity\": 0 },
                                    \"S3OriginConfig\": { \"OriginAccessIdentity\": \"\" },
                                    \"OriginAccessControlId\": \"${OAC_ID}\"
                                }
                            ]
                        },
                        \"DefaultCacheBehavior\": {
                            \"TargetOriginId\": \"${S3_ORIGIN_DOMAIN}\",
                            \"ViewerProtocolPolicy\": \"redirect-to-https\",
                            \"AllowedMethods\": {
                                \"Quantity\": 3,
                                \"Items\": [\"GET\", \"HEAD\", \"OPTIONS\"],
                                \"CachedMethods\": { \"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"] }
                            },
                            \"ForwardedValues\": {
                                \"QueryString\": false,
                                \"Cookies\": { \"Forward\": \"none\" },
                                \"Headers\": { \"Quantity\": 0 },
                                \"QueryStringCacheKeys\": { \"Quantity\": 0 }
                            },
                            \"MinTTL\": 0,
                            \"Compress\": true
                        },
                        \"CustomErrorResponses\": {
                            \"Quantity\": 2,
                            \"Items\": [
                                {
                                    \"ErrorCode\": 403,
                                    \"ResponsePagePath\": \"/index.html\",
                                    \"ResponseCode\": \"200\",
                                    \"ErrorCachingMinTTL\": 0
                                },
                                {
                                    \"ErrorCode\": 404,
                                    \"ResponsePagePath\": \"/index.html\",
                                    \"ResponseCode\": \"200\",
                                    \"ErrorCachingMinTTL\": 0
                                }
                            ]
                        },
                        \"Restrictions\": {
                            \"GeoRestriction\": { \"RestrictionType\": \"none\", \"Quantity\": 0 }
                        },
                        \"ViewerCertificate\": {
                            \"CloudFrontDefaultCertificate\": true,
                            \"MinimumProtocolVersion\": \"TLSv1\"
                        }
                    }" \
                    --output text \
                    --query 'Distribution.Id')
            fi
        else
            # Check if CloudFront distribution already exists for the domain
            DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items[0]=='${APP_URL}'].Id | [0]" --output text)
            if ! is_blank_aws_value "${DIST_ID}"; then
                echo "CloudFront distribution already exists for the domain ${APP_URL}"
            else
                DIST_ID=""
                # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/example_cloudfront_CreateDistribution_section.html

                echo "Creating CloudFront distribution..."
                DIST_ID=$(aws cloudfront create-distribution \
                --distribution-config "{
                    \"Comment\": \"CloudFront Distribution for '${BUCKET_NAME}'\",
                    \"Enabled\": true,
                    \"Aliases\": {
                        \"Quantity\": 1,
                        \"Items\": [\"${APP_URL}\"]
                    },
                    \"DefaultRootObject\": \"index.html\",
                    \"Origins\": {
                        \"Quantity\": 1,
                        \"Items\": [
                            {
                                \"Id\": \"${S3_ORIGIN_DOMAIN}\",
                                \"DomainName\": \"${S3_ORIGIN_DOMAIN}\",
                                \"OriginPath\": \"\",
                                \"CustomHeaders\": {
                                    \"Quantity\": 0
                                },
                                \"S3OriginConfig\": {
                                    \"OriginAccessIdentity\": \"\"
                                },
                                \"OriginAccessControlId\": \"${OAC_ID}\"
                            }
                        ]
                    },
                    \"CallerReference\": \"${BUCKET_NAME}-distribution\",
                    \"ViewerCertificate\": {
                        \"CertificateSource\": \"acm\",
                        \"SSLSupportMethod\": \"sni-only\",
                        \"ACMCertificateArn\": \"${AWS_SSL_CERTIFICATE_ARN}\",
                        \"MinimumProtocolVersion\": \"TLSv1.2_2019\"
                    },
                    \"DefaultCacheBehavior\": {
                        \"TargetOriginId\": \"${S3_ORIGIN_DOMAIN}\",
                        \"ViewerProtocolPolicy\": \"redirect-to-https\",
                        \"AllowedMethods\": {
                            \"Quantity\": 3,
                            \"Items\": [\"GET\", \"HEAD\", \"OPTIONS\"],
                            \"CachedMethods\": { \"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"] }
                        },
                        \"ForwardedValues\": {
                            \"QueryString\": false,
                            \"Cookies\": {
                                \"Forward\": \"none\"
                            },
                            \"Headers\": {
                                \"Quantity\": 0
                            },
                            \"QueryStringCacheKeys\": {
                                \"Quantity\": 0
                            }
                        },
                        \"MinTTL\": 0,
                        \"Compress\": true
                    },
                    \"CustomErrorResponses\": {
                        \"Quantity\": 2,
                        \"Items\": [
                            {
                                \"ErrorCode\": 403,
                                \"ResponsePagePath\": \"/index.html\",
                                \"ResponseCode\": \"200\",
                                \"ErrorCachingMinTTL\": 0
                            },
                            {
                                \"ErrorCode\": 404,
                                \"ResponsePagePath\": \"/index.html\",
                                \"ResponseCode\": \"200\",
                                \"ErrorCachingMinTTL\": 0
                            }
                        ]
                    },
                    \"Restrictions\": {
                        \"GeoRestriction\": { \"RestrictionType\": \"none\", \"Quantity\": 0 }
                    }
                }" \
                --output text \
                --query 'Distribution.Id')

                if is_blank_aws_value "${DIST_ID}"; then
                    DIST_ID=""
                    ERROR_MSG="ERROR: the cloudfront create-distribution for S3 bucket '${BUCKET_NAME}' and Domain '${APP_URL}' failed..."
                    continue_or_stop
                fi
            fi
        fi
    fi

    if [ "${ERROR_MSG:-}" = "" ]; then
        if is_blank_aws_value "${DIST_ID}"; then
            ERROR_MSG="ERROR: CloudFront distribution ID is empty"
        else
            echo ""
            echo "CloudFront distribution ID: $DIST_ID"
        fi
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    # Attach OAC to existing distributions that were created without it (fixes AccessDenied).
    if ! attach_oac_to_distribution "${DIST_ID}" "${OAC_ID}"; then
        ERROR_MSG="ERROR attaching CloudFront OAC '${OAC_ID}' to distribution '${DIST_ID}'"
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    # Keep the bucket private: only the CloudFront distribution (via OAC) may GetObject.
    # Do not add Principal:"*" (PublicReadGetObject) — that bypasses CloudFront.
    # Do not use bucket/object ACLs: Object Ownership is BucketOwnerEnforced.
    echo "Ensuring Object Ownership is BucketOwnerEnforced and public access is blocked..."
    aws s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' --profile "$AWS_PROFILE" --region "${AWS_REGION}" --output text
    aws s3api put-public-access-block --bucket "$BUCKET_NAME" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" --profile "$AWS_PROFILE" --region "${AWS_REGION}" --output text
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    # Grant s3:GetObject only to this CloudFront distribution (OAC), matching frontend-hosting TF module.
    echo "Adding permissions to the S3 bucket policy to allow access from CloudFront OAC..."
    S3_BUCKET_POLICY="{
\"Version\":\"2012-10-17\",
\"Statement\":[
    {
        \"Sid\":\"AllowCloudFrontOACAccess\",
        \"Effect\":\"Allow\",
        \"Principal\":{\"Service\":\"cloudfront.amazonaws.com\"},
        \"Action\":\"s3:GetObject\",
        \"Resource\":\"arn:aws:s3:::${BUCKET_NAME}/*\",
        \"Condition\":{
            \"StringEquals\":{
                \"AWS:SourceArn\":\"arn:aws:cloudfront::${AWS_ACCOUNT_ID}:distribution/${DIST_ID}\"
            }
        }
    }
]
}"
    echo "S3_BUCKET_POLICY: $S3_BUCKET_POLICY"
    if BUCKET_POLICY_RESULT=$(aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" --policy "${S3_BUCKET_POLICY}" --output text); then
        echo "S3 bucket policy updated (CloudFront OAC-only; bucket remains private)"
        echo "BUCKET_POLICY_RESULT: $BUCKET_POLICY_RESULT"

        echo $(aws s3api get-bucket-policy --bucket "${BUCKET_NAME}" --output text)
        echo $(aws cloudfront get-distribution-config --id "${DIST_ID}" --output text)
    else
        ERROR_MSG="ERROR running aws s3api put-bucket-policy --bucket ${BUCKET_NAME} --policy ${S3_BUCKET_POLICY}"
        echo ""
        echo "${ERROR_MSG}"
        echo ""
        echo "The bucket policy could not be applied. Keep 'Block all public access' enabled;"
        echo "this script only grants s3:GetObject to CloudFront OAC (not anonymous public read)."
        echo ""
        echo "Check that:"
        echo "  - The OAC ID '${OAC_ID}' is attached to distribution '${DIST_ID}'"
        echo "  - Your credentials allow s3:PutBucketPolicy on '${BUCKET_NAME}'"
        echo "  - Object Ownership is BucketOwnerEnforced (ACLs disabled)"
        echo ""
        echo "To link this S3 bucket to the '${APP_URL}' domain via CloudFront:"
        echo ""
        echo "1) Go to Route 53"
        echo "2) Click on the Zone corresponding to the domain of '${APP_URL}'"
        echo "3) Click on 'Create Record'"
        echo "4) Enter the subdomain part of '${APP_URL}'"
        echo "5) Enable 'alias'"
        echo "6) In 'Route traffic to' select the 'Alias to CloudFront' option"
        echo "7) In 'Choose distribution' select the one corresponding to '${APP_URL}'"
        echo "8) Click on 'Create Records'"
        echo ""
        echo "Then retry this script..."
        echo ""
        continue_or_stop
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then

    # Get CloudFront domain name
    echo "Getting CloudFront domain name..."
    DOMAIN_NAME=$(aws cloudfront get-distribution --id ${DIST_ID} --query 'Distribution.DomainName' --output text)
    echo "CloudFront domain name: $DOMAIN_NAME"
fi

if [ "${ERROR_MSG:-}" = "" ]; then

    if [ "${RUN_BUNDLER}" != "none" ]; then
        bash "${SCRIPTS_DIR}/run_method_dependency_manager.sh" install ${RUN_BUNDLER}

        export TSCONFIG_BASE_URL=$(perl -ne 'print $1 if /"baseUrl":\s*"([^"]*)"/' tsconfig.json)
        echo "tsconfig.json TSCONFIG_BASE_URL was: ${TSCONFIG_BASE_URL}"

        if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
            echo "Preparing tsconfig.json for local build test..."
            perl -i -pe"s|\"baseUrl\": \"./src/lib\"|\"baseUrl\": \"./src\"|g" tsconfig.json
        fi

        export PREV_HOME_PAGE=$(perl -ne 'print $1 if /"homepage":\s*"([^"]*)"/' package.json)
        export DEPLOYMENT_HOME_PAGE="https:\/\/${DOMAIN_NAME}"

        echo ""
        echo "Updating package.json homepage with cloudfront domain..."
        echo ""
        echo "Previous homepage: ${PREV_HOME_PAGE}"
        echo "Assigned homepage during deployment: ${DEPLOYMENT_HOME_PAGE}"
        echo ""
        if ! perl -i -pe"s|\"homepage\":.*|\"homepage\": \"${DEPLOYMENT_HOME_PAGE}\",|g" package.json
        then
            ERROR_MSG="ERROR updating package.json homepage with cloudfront domain ${DOMAIN_NAME}"
        else
            echo "package.json homepage updated"
        fi

        # Prevent ERR_REQUIRE_ESM on libraries
        if [ "${PRESERVE_MODULE_TYPE:-}" != "1" ]; then
            rename_module_type
        else
            echo "Preserving module type in package.json"
            restore_module_type
        fi
    fi
fi

# Build the ReactJS project
if [ "${ERROR_MSG:-}" = "" ]; then
    if [ "${UPDATE_BUILD}" = "1" ]; then

        # To avoid error message: "ENOENT: no such file or directory, stat './public/static'"
        # during the build process, because the 'static' is a symlink, not a directory
        remove_symlinks

        echo "Building React app... (${RUN_BUNDLER})"

        if [ "${1:-}" = "prod" ]; then
            echo "Building for production..."
            if [ "${RUN_BUNDLER}" = "webpack" ]; then
                run_command="npx webpack --mode production"
            elif [ "${RUN_BUNDLER}" = "vite" ]; then
                run_command="npx vite build"
            else
                run_command="npx react-app-rewired build"
            fi
            if ! ${run_command}
            then
                ERROR_MSG="ERROR-010 running ${run_command}"
            fi
        else
            echo "Building for development ($1)..."
            if [ "${RUN_BUNDLER}" = "webpack" ]; then
                run_command="npx webpack --mode development"
            elif [ "${RUN_BUNDLER}" = "vite" ]; then
                run_command="npx vite build"
            else
                run_command="npx react-app-rewired build"
            fi
            if ! ${run_command}
            then
                ERROR_MSG="ERROR-020 running ${run_command}"
            fi
        fi

        if [ "${ERROR_MSG:-}" = "" ]; then
            # Copy images to build/static/media directory
            if ! source ${SCRIPTS_DIR}/build_copy_images.sh "" ""
            then
                ERROR_MSG="ERROR running: source ${SCRIPTS_DIR}/build_copy_images.sh"
            fi
        fi
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    echo "Deploying to AWS S3..."
    # No --acl: incompatible with BucketOwnerEnforced (AccessControlListNotSupported).
    if ! aws s3 sync "${BUILD_DIR}" "s3://${BUCKET_NAME}" --delete --region "${AWS_REGION}" --output text
    then
        ERROR_MSG="ERROR running aws s3 sync ${BUILD_DIR}/ s3://${BUCKET_NAME} --delete --region ${AWS_REGION} --output text"
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then

    if [ "${RUN_BUNDLER}" != "none" ]; then
        echo "Updating package.json homepage (Restore)..."
        # if ! perl -i -pe"s|\"homepage\": \"https:\/\/$DOMAIN_NAME\"|\"homepage\": \"https:\/\/${GITHUB_USERNAME}.github.io\/${GITHUB_REPONAME}\/\"|g" package.json
        if ! perl -i -pe"s|\"homepage\":.*|\"homepage\": \"${PREV_HOME_PAGE}\",|g" package.json
        then
            # ERROR_MSG="ERROR running perl -i -pe's|\"homepage\": \"https:\/\/$DOMAIN_NAME\/\"|\"homepage\": \"https:\/\/${GITHUB_USERNAME}.github.io\/${GITHUB_REPONAME}\/\"|g' package.json"
            ERROR_MSG="ERROR running perl -i -pe\"s|\"homepage\":.*|\"homepage\": \"${PREV_HOME_PAGE}\",|g\" package.json"
        fi

        # Revert prevent ERR_REQUIRE_ESM on libraries
        restore_module_type

        if [ "${TSCONFIG_BASE_URL}" = "./src/lib" ]; then
            echo ""
            echo "tsconfig.json TSCONFIG_BASE_URL will be restored to: ${TSCONFIG_BASE_URL}"
            perl -i -pe"s|\"baseUrl\": \"./src\"|\"baseUrl\": \"./src/lib\"|g" tsconfig.json
        fi
    fi
fi

if [ "${ERROR_MSG:-}" = "" ]; then
    # Invalidate CloudFront cache
    echo "Invalidating CloudFront cache..."
    if CLOUDFRONT_CREATE_INVALIDATION_RESULT=$(aws cloudfront create-invalidation --distribution-id $DIST_ID --paths "/*"); then
        echo "CLOUDFRONT_CREATE_INVALIDATION_RESULT: $CLOUDFRONT_CREATE_INVALIDATION_RESULT"
    else
        ERROR_MSG="ERROR running aws cloudfront create-invalidation --distribution-id ${DIST_ID} --paths /*"
    fi
fi

echo ""
if [ "${ERROR_MSG:-}" = "" ]; then
    echo "Deployment complete."
else
    echo "ERROR: ${ERROR_MSG}"
fi
echo ""
