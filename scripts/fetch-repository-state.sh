#!/usr/bin/env bash
# Prepare the publish state: download the currently published repository from
# R2 so the next publish adds to it instead of starting over.
#
# The bucket is the only copy of the repository, so this step is what keeps a
# single failed upload from erasing packages: whatever is in the bucket comes
# back, gets the new builds merged into its database, and is published again.
#
# A missing database is not an error -- the very first publish has nothing to
# fetch -- but an authentication or network failure that *looks* like a missing
# database is, and would republish an empty repository over a full one. So the
# bucket is listed first: if the listing works and finds nothing, it really is
# empty; if the listing fails, the whole step fails.
#
# Environment:
#   REPOSITORY_DIR   where to place the fetched repository
#   REPOSITORY_NAME  pacman repository name
#   R2_BUCKET, R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_PREFIX
#                    as for publish-r2.sh (R2_* are optional when the bucket is
#                    new: listing an unconfigured bucket is reported instead of
#                    silently treated as empty)

set -Eeuo pipefail

for variable in REPOSITORY_DIR REPOSITORY_NAME; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'Missing required environment variable: %s\n' "$variable" >&2
        exit 2
    fi
done

readonly state_dir="${REPOSITORY_DIR}"
readonly repository_name="${REPOSITORY_NAME}"
readonly bucket="${R2_BUCKET:-}"
readonly endpoint="${R2_ENDPOINT:-}"
readonly prefix="${R2_PREFIX:-x86_64-v3}"

mkdir -p "$state_dir"

if [[ -z "$bucket" || -z "$endpoint" ]]; then
    printf 'R2 is not configured (R2_BUCKET/R2_ENDPOINT unset); starting from an empty repository.\n'
    exit 0
fi

# `AWS_ENDPOINT_URL_S3` only exists in aws-cli 2.13 and later; older builds
# ignore it and then talk to Amazon S3, where these keys mean nothing. The
# failure looks like "the bucket is empty", which this script is specifically
# built to never mistake for a real answer -- so pass --endpoint-url explicitly
# instead of relying on the variable.
export AWS_ENDPOINT_URL_S3="${endpoint%/}"
export AWS_DEFAULT_REGION="auto"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"

printf 'AWS CLI: %s\n' "$(aws --version 2>&1 || echo unknown)"

command -v aws >/dev/null 2>&1 || {
    printf 'The AWS CLI is required to fetch the published repository.\n' >&2
    exit 1
}

# The listing is the existence proof described in the header.
#
# It is `s3api list-objects-v2`, not `s3 ls`: with a trailing slash `s3 ls`
# sends a delimiter and aws-cli exits non-zero when the answer is empty, so an
# empty bucket and a broken credential both come back as "command failed".
# `list-objects-v2` writes `(empty)` and exits 0 for a real empty result, and
# keeps a genuine failure a failure.
#
# Diagnostics go to files rather than to a variable: a command substitution
# that only holds stdout is how a real CLI error turns into a blank
# "failed (attempt 1):" line, which is the state that made the first R2
# publish impossible to debug.
listing_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$listing_file" "$error_file"' EXIT
for attempt in 1 2 3; do
    if timeout 120 aws --endpoint-url "${endpoint%/}" s3api list-objects-v2 \
        --bucket "$bucket" --prefix "${prefix}/" \
        --query 'Contents[].[Key]' --output text \
        >"$listing_file" 2>"$error_file"; then
        listing="$(cat "$listing_file")"
        # The CLI prints the literal word None when there are no objects.
        if [[ "$listing" == "None" ]]; then
            listing=""
        fi
        break
    fi
    printf 'Listing s3://%s/%s/ failed (attempt %d):\n' \
        "$bucket" "$prefix" "$attempt" >&2
    if [[ -s "$error_file" ]]; then
        sed 's/^/  /' "$error_file" >&2
    else
        printf '  (the AWS CLI exited without writing an error; check credentials, bucket, and endpoint)\n' >&2
    fi
    if (( attempt == 3 )); then
        printf 'Cannot establish whether the published repository exists; refusing to start from empty.\n' >&2
        exit 1
    fi
    sleep $(( attempt * 5 ))
    listing=""
done

if [[ -z "$listing" ]]; then
    printf 's3://%s/%s/ is empty; first publish starts with an empty repository.\n' \
        "$bucket" "$prefix"
    exit 0
fi

# `list-objects-v2` yields keys relative to the bucket root, so the database
# appears as "${prefix}/${name}.db" -- the separator to match is the slash, not
# the leading whitespace `s3 ls` would have produced.
if ! grep -qE "(^|/)${repository_name}\.(db|files)$" <<< "$listing"; then
    printf 's3://%s/%s/ has objects but no %s database:\n%s\n' \
        "$bucket" "$prefix" "$repository_name" "$listing" >&2
    printf 'Refusing to publish over a prefix whose database is missing.\n' >&2
    exit 1
fi

printf 'Downloading the published repository from s3://%s/%s/\n' "$bucket" "$prefix"
# Only the metadata and packages are needed; the ABI manifest and keyring are
# small and harmless to fetch too, and keeping the directory identical to the
# bucket means the republished database refers to files that are already there.
timeout 1800 aws --endpoint-url "${endpoint%/}" s3 cp --only-show-errors --no-progress --recursive \
    "s3://${bucket}/${prefix}/" "$state_dir/"

find "$state_dir" -maxdepth 1 -type f -printf '%f %k KiB\n' | sort | tail -20
printf 'Fetched %d file(s).\n' "$(find "$state_dir" -maxdepth 1 -type f | wc -l)"
