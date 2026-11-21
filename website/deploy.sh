#!/bin/bash
# Upload website/site to the S3 bucket behind CloudFront, then invalidate.
# Credentials come from the normal AWS CLI chain (env vars or a profile);
# none live in this repo. Usage: AWS_PROFILE=<profile> website/deploy.sh
set -euo pipefail
BUCKET=tripperdash-kolaczek-site
DISTRIBUTION=EJR8RN8P8LIL3
export AWS_DEFAULT_REGION=eu-central-1
cd "$(dirname "$0")/site"

up() { aws s3 cp "$1" "s3://$BUCKET/$2" --content-type "$3" --cache-control "$4" --only-show-errors; }
HTML="public,max-age=300"; ASSET="public,max-age=86400"

for f in $(find . -type f | sed 's#^\./##' | sort); do
  case "$f" in
    *.html) up "$f" "$f" "text/html;charset=utf-8" "$HTML" ;;
    *.css)  up "$f" "$f" "text/css;charset=utf-8" "$HTML" ;;
    *.xml)  up "$f" "$f" "application/xml;charset=utf-8" "public,max-age=3600" ;;
    *.txt)  up "$f" "$f" "text/plain;charset=utf-8" "public,max-age=3600" ;;
    *.woff2) up "$f" "$f" font/woff2 "public,max-age=31536000,immutable" ;;
    *.webp) up "$f" "$f" image/webp "$ASSET" ;;
    *.png)  up "$f" "$f" image/png "$ASSET" ;;
    *.jpg)  up "$f" "$f" image/jpeg "$ASSET" ;;
    *.svg)  up "$f" "$f" image/svg+xml "$ASSET" ;;
    *.ico)  up "$f" "$f" image/x-icon "$ASSET" ;;
    *) echo "unknown type: $f" >&2; exit 1 ;;
  esac
done
# CloudFront asks S3 for /support and /changelog (no trailing slash, no index document).
up support/index.html support "text/html;charset=utf-8" "$HTML"
up changelog/index.html changelog "text/html;charset=utf-8" "$HTML"

aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION" --paths "/*" \
  --query 'Invalidation.Id' --output text
