#!/usr/bin/env bash
# Publish the local pacman repository directory to a Cloudflare R2 bucket.
#
# pacman reads a repository as "one database plus a flat directory of package
# files", so the bucket layout is fixed:
#
#   <prefix>/<repo>.db, <repo>.db.tar.zst
#   <prefix>/<repo>.files, <repo>.files.tar.zst
#   <prefix>/<repo>.db.sig, <repo>.files.sig     (when signing)
#   <prefix>/<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
#
# The bucket is the repository: there is no second copy, so an upload that
# half-succeeds leaves clients with a database naming packages that are not
# there yet. Two rules encode that:
#
#   1. Packages go first, the database goes last. A client that reads the
#      database during the upload therefore sees the previous complete state.
#   2. Package files are immutable (a given filename always has the same
#      bytes) and are cached forever; the database is never cached, because a
#      cached database pins every client to an old package list.
#
# Files already present with the same content are skipped, and package files
# the new database no longer references are deleted -- three repositories' worth
# of stale .pkg.tar.zst otherwise accumulate and every one of them is a file
# pacman may never fetch again.
#
# Environment:
#   REPOSITORY_DIR     directory holding the built repository (published/x86_64-v3)
#   REPOSITORY_NAME    pacman repository name (fuego-repo)
#   R2_BUCKET          bucket name
#   R2_ENDPOINT        https://<account>.r2.cloudflarestorage.com
#   R2_ACCESS_KEY_ID   \
#   R2_SECRET_ACCESS_KEY  > S3 credentials with object read/write on the bucket
#   R2_PREFIX          optional key prefix (default: x86_64-v3)
#   AWS_ENDPOINT_URL_S3 set by this script from R2_ENDPOINT
#
# Uses the AWS CLI, which is preinstalled on the GitHub-hosted runner. It is
# not in the CachyOS builder image and does not need to be: publishing happens
# on the runner, the builder only produces the packages.

set -Eeuo pipefail

for variable in REPOSITORY_DIR REPOSITORY_NAME R2_BUCKET R2_ENDPOINT \
    R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'Missing required environment variable: %s\n' "$variable" >&2
        if [[ "$variable" == R2_PUBLIC_URL ]]; then
            printf 'It is the URL clients use; without it the database .conf points nowhere.\n' >&2
        fi
        exit 2
    fi
done

readonly repository_dir="${REPOSITORY_DIR}"
readonly repository_name="${REPOSITORY_NAME}"
readonly bucket="${R2_BUCKET}"
readonly endpoint="${R2_ENDPOINT%/}"
readonly prefix="${R2_PREFIX:-x86_64-v3}"

export AWS_ENDPOINT_URL_S3="$endpoint"
export AWS_DEFAULT_REGION="auto"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"

command -v aws >/dev/null 2>&1 || {
    printf 'The AWS CLI is required to publish to R2.\n' >&2
    exit 1
}

for required in "${repository_name}.db" "${repository_name}.files"; do
    if [[ ! -f "${repository_dir}/${required}" ]]; then
        printf 'Repository database is missing in %s: %s\n' \
            "$repository_dir" "$required" >&2
        exit 1
    fi
done

cd "$repository_dir"

# Metadata is everything that describes the repository; everything else that
# ends in .pkg.tar.zst is payload. Packages upload first (see the header).
metadata_names=(
    "${repository_name}.db"
    "${repository_name}.db.tar.zst"
    "${repository_name}.files"
    "${repository_name}.files.tar.zst"
    "${repository_name}.db.sig"
    "${repository_name}.files.sig"
    "${repository_name}.conf"
    "${repository_name}-key.asc"
    "${repository_name}-abi-manifest.txt"
    "SHA256SUMS"
)

is_metadata() {
    local name="$1" candidate
    for candidate in "${metadata_names[@]}"; do
        [[ "$name" == "$candidate" ]] && return 0
    done
    return 1
}

mapfile -d '' payload < <(find . -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0 | sort -z)
mapfile -d '' metadata < <(
    for name in "${metadata_names[@]}"; do
        [[ -f "$name" ]] && printf '%s\0' "$name"
    done
)

if (( ${#payload[@]} == 0 )); then
    printf 'No package files in %s; refusing to publish an empty repository.\n' \
        "$repository_dir" >&2
    exit 1
fi

# Content hashes, not sizes. A package filename embeds the version, pkgrel and
# architecture but NOT the build: rebuilding the same PKGBUILD without bumping
# pkgrel produces the same filename, and a size comparison would then skip the
# upload whenever the new archive happened to compress to the same length --
# silently leaving the old bytes in the bucket while the log says "unchanged".
# That is the same class of failure as a drift check that cannot compare and
# reports no drift, so the decision is made on the SHA-256 the object carries
# in its own metadata.
#
# The hash is written as x-amz-meta-sha256 on upload and read back with a HEAD
# request. Objects published before this scheme have no such metadata; they
# are uploaded once and then carry it, so the cost is paid a single time.
sha256_of() {
    local file="$1" output
    output="$(sha256sum -- "$file")"
    printf '%s' "${output%% *}"
}

printf 'Listing existing objects under %s/\n' "$prefix"
declare -A remote_size=()
while IFS=$'\t' read -r size key; do
    [[ -n "$key" ]] || continue
    remote_size["${key##*/}"]="$size"
done < <(
    aws s3api list-objects-v2 \
        --bucket "$bucket" --prefix "${prefix}/" \
        --query 'Contents[].[Size,Key]' --output text 2>/dev/null || true
)

# One HEAD per existing package: the object is small in metadata and the
# request is cheap, and it is the only way to tell "same name, different
# bytes" from "same object".
declare -A remote_sha256=()
pending=()
skipped=0
for file in "${payload[@]}"; do
    name="$(basename "$file")"
    local_sha256="$(sha256_of "$file")"
    if [[ -n "${remote_size[$name]:-}" ]]; then
        stored="$(aws s3api head-object \
            --bucket "$bucket" --key "${prefix}/${name}" \
            --query 'Metadata.sha256' --output text 2>/dev/null || true)"
        if [[ "$stored" == "$local_sha256" ]]; then
            remote_sha256["$name"]="$local_sha256"
            skipped=$(( skipped + 1 ))
            continue
        fi
        if [[ -n "$stored" && "$stored" != "None" ]]; then
            printf 'Package content changed but the name is the same: %s\n' "$name"
            printf '  bucket: %s\n  built:  %s\n' "$stored" "$local_sha256"
            printf 'This means the PKGBUILD was rebuilt without a pkgrel bump.\n' >&2
        fi
    fi
    pending+=("$file")
    remote_sha256["$name"]="$local_sha256"
done

if (( ${#pending[@]} > 0 )); then
    printf 'Uploading %d package file(s)\n' "${#pending[@]}"
    # Package files never change once named, so they are cached for a year.
    # Each upload carries its SHA-256 so the next publish can compare content
    # instead of guessing from the size.
    for file in "${pending[@]}"; do
        name="$(basename "$file")"
        aws s3 cp --only-show-errors --no-progress \
            --cache-control 'public, max-age=31536000, immutable' \
            --metadata "sha256=${remote_sha256[$name]}" \
            "$file" "s3://${bucket}/${prefix}/${name}"
    done
fi

# Database last: a client must never see a database naming a file that is not
# uploaded yet. The database itself is never cached.
printf 'Uploading repository metadata\n'
for file in "${metadata[@]}"; do
    aws s3 cp --only-show-errors --no-progress \
        --cache-control 'no-cache, no-store, must-revalidate' \
        "$file" "s3://${bucket}/${prefix}/${file}"
done

# Delete package files the new database no longer references. Derived from the
# database rather than from a timestamp: files that are present but unlisted
# are unreachable by pacman and only cost storage.
printf 'Pruning packages no longer referenced\n'
referenced="$(mktemp)"
trap 'rm -f "$referenced"' EXIT
# The database tar contains <lib-directory>/ entries plus one
# "<name>-<ver>/desc" per package. Only desc carries %FILENAME%, which is the
# field pacman itself uses to locate the file -- asking for just those members
# avoids reading a directory entry as if it were a package record.
repo_db_tar="${repository_name}.db.tar.zst"
[[ -f "$repo_db_tar" ]] || repo_db_tar="${repository_name}.db.tar.gz"
tar -xOf "$repo_db_tar" --wildcards '*/desc' 2>/dev/null |
    awk -F ' = ' '$1 == "%FILENAME%" { print $2 }' | sort -u > "$referenced"
if [[ ! -s "$referenced" ]]; then
    # Never prune from an empty list: a database that could not be read would
    # otherwise delete every package in the bucket.
    printf 'Could not read package filenames from %s; skipping the prune.\n' \
        "$repo_db_tar" >&2
fi

deleted=0
if [[ -s "$referenced" ]]; then
for name in "${!remote_size[@]}"; do
    [[ "$name" == *.pkg.tar.zst ]] || continue
    if ! grep -qxF -- "$name" "$referenced"; then
        printf 'Deleting unreferenced package: %s\n' "$name"
        aws s3 rm --only-show-errors "s3://${bucket}/${prefix}/${name}"
        deleted=$(( deleted + 1 ))
    fi
done
fi

# Verify what a client will actually see: fetch the database back and compare
# with the local copy. An upload that silently truncated would otherwise look
# successful in the log and fail for every user instead.
printf 'Verifying the published database\n'
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"; rm -f "$referenced"' EXIT
aws s3 cp --only-show-errors --no-progress \
    "s3://${bucket}/${prefix}/${repository_name}.db" \
    "${verify_dir}/${repository_name}.db"
if ! cmp -s "${verify_dir}/${repository_name}.db" "${repository_name}.db"; then
    printf 'Published database does not match the built one.\n' >&2
    exit 1
fi

# No fallback to the S3 endpoint: that URL is not public, so a .conf built
# from it would look valid here and fail for every client. README carries the
# value and the workflow checks it before anything is uploaded.
server_url="${R2_PUBLIC_URL%/}"
package_count="${#payload[@]}"
updated_at="$(date -u '+%Y-%m-%d %H:%M UTC')"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '## Published to R2\n\n'
        printf -- '- Bucket prefix: `s3://%s/%s`\n' "$bucket" "$prefix"
        printf -- '- Package files: %d (uploaded %d, unchanged %d)\n' \
            "$package_count" "${#pending[@]}" "$skipped"
        printf -- '- Pruned: %d\n' "$deleted"
        printf -- '- Updated: %s\n' "$updated_at"
        printf -- '- Client entry:\n\n'
        printf '```ini\n[%s]\nServer = %s\n```\n' "$repository_name" "$server_url"
    } >> "$GITHUB_STEP_SUMMARY"
fi

printf 'Published %d package(s) to s3://%s/%s (%d uploaded, %d unchanged, %d pruned).\n' \
    "$package_count" "$bucket" "$prefix" "${#pending[@]}" "$skipped" "$deleted"
printf 'Clients use: Server = %s\n' "$server_url"
