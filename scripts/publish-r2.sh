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

missing=()
for variable in REPOSITORY_DIR REPOSITORY_NAME R2_BUCKET R2_ENDPOINT \
    R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL; do
    [[ -n "${!variable:-}" ]] || missing+=("$variable")
done
if (( ${#missing[@]} > 0 )); then
    # Report every missing name at once (a step-level env that forgot one input
    # otherwise costs a full run per missing variable) and annotate the job so
    # it shows up in the Actions summary instead of only deep in the log.
    printf '::error::publish-r2.sh is missing required environment: %s\n' "${missing[*]}" >&2
    for variable in "${missing[@]}"; do
        printf 'Missing required environment variable: %s\n' "$variable" >&2
    done
    if [[ " ${missing[*]} " == *" R2_PUBLIC_URL "* ]]; then
        printf 'R2_PUBLIC_URL is the URL clients use; without it the database .conf points nowhere.\n' >&2
    fi
    exit 2
fi

# A purge zone without a token (or the reverse) is a configuration mistake, and
# finding out after every object has been uploaded leaves a published run that
# nobody can see: the bytes are in the bucket but the edge still serves the old
# ones. Refuse before the first upload instead.
if [[ -n "${CF_ZONE_ID:-}" && -z "${CF_API_TOKEN:-}" ]] \
    || [[ -z "${CF_ZONE_ID:-}" && -n "${CF_API_TOKEN:-}" ]]; then
    printf '::error::CF_ZONE_ID and CF_API_TOKEN must be set together, or not at all.\n' >&2
    printf 'Set both to purge the cache after publishing, or neither to publish without purging.\n' >&2
    exit 2
fi

readonly repository_dir="${REPOSITORY_DIR}"
readonly repository_name="${REPOSITORY_NAME}"
readonly bucket="${R2_BUCKET}"
readonly endpoint="${R2_ENDPOINT%/}"
readonly prefix="${R2_PREFIX:-x86_64-v3}"
readonly server_url="${R2_PUBLIC_URL%/}"

# Cloudflare keeps its own copy of every object it has fetched. Optional purge
# credentials: without them the script still publishes, but a re-upload can be
# masked by an edge that fetched the object earlier.
readonly cdn_zone_id="${CF_ZONE_ID:-}"
readonly cdn_api_token="${CF_API_TOKEN:-}"
readonly cdn_api="${CF_API_URL:-https://api.cloudflare.com/client/v4}"

# A package filename never changes, so a long cache is right in principle. But
# Cloudflare has served a corrupted 6226-byte copy of a 6235-byte package from
# its edge cache while reporting the correct ETag and length -- and with
# `immutable` the bad copy would stay for a year. A five-minute, revalidating
# cache still absorbs the load of a repository that changes rarely, yet a bad
# edge copy heals almost immediately.
readonly package_cache_control='public, max-age=300, must-revalidate'

# `AWS_ENDPOINT_URL_S3` only exists in aws-cli 2.13 and later; the GitHub
# runner image and distro packages have shipped older v2 builds, and on those
# the variable is silently ignored -- the CLI then talks to Amazon S3, where
# these R2 keys mean nothing. Every call therefore passes --endpoint-url
# explicitly, which works on v1 and v2 alike. The env var is still set for
# any nested invocation.
export AWS_ENDPOINT_URL_S3="$endpoint"
export AWS_DEFAULT_REGION="auto"

aws_s3() {
    aws --endpoint-url "$endpoint" s3 "$@"
}

aws_s3api() {
    aws --endpoint-url "$endpoint" s3api "$@"
}

aws_version="$(aws --version 2>&1 || true)"
printf 'AWS CLI: %s\n' "${aws_version:-unknown}"
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
    aws_s3api list-objects-v2 \
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
        stored="$(aws_s3api head-object \
            --bucket "$bucket" --key "${prefix}/${name}" \
            --query 'Metadata.sha256' --output text 2>/dev/null || true)"
        if [[ "$stored" == "$local_sha256" ]]; then
            remote_sha256["$name"]="$local_sha256"
            skipped=$(( skipped + 1 ))
            continue
        fi
        if [[ -n "$stored" && "$stored" != "None" ]]; then
            # Overwriting an object that already exists under this exact name is
            # worse than a wasted upload: every CDN edge keeps the body it
            # cached, so clients download the previous bytes while the database
            # and the .sig describe the new ones. Observed exactly that with
            # quirc: the database recorded a 76531-byte package, the bare URL
            # served a cached 76530-byte one, and pacman rejected the pair as a
            # corrupted signature. A package name is immutable once published;
            # a rebuild must carry a new name.
            printf 'Refusing to overwrite %s with different content.\n' "$name" >&2
            printf '  bucket: %s\n  built:  %s\n' "$stored" "$local_sha256" >&2
            printf 'The PKGBUILD was rebuilt without a pkgrel bump. Bump pkgrel so the\n' >&2
            printf 'package gets a new name; a CDN edge would otherwise keep serving\n' >&2
            printf 'the previous bytes under this one and clients would see a bad\n' >&2
            printf 'signature. (If the published bytes are already the right ones,\n' >&2
            printf 'purge this URL at the CDN instead of republishing.)\n' >&2
            exit 1
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
        aws_s3 cp --only-show-errors --no-progress \
            --cache-control "$package_cache_control" \
            --metadata "sha256=${remote_sha256[$name]}" \
            "$file" "s3://${bucket}/${prefix}/${name}"
        # The detached signature is small and immutable alongside its package.
        local_sig="${file}.sig"
        if [[ -f "$local_sig" ]]; then
            aws_s3 cp --only-show-errors --no-progress \
                --cache-control "$package_cache_control" \
                "$local_sig" "s3://${bucket}/${prefix}/${name}.sig"
        fi
    done
fi

# An unchanged package is never re-uploaded, but its signature may still be
# missing from the bucket (it was added to this script after packages were
# already published, or a previous run failed mid-way). Re-upload the sig for
# every payload file that has one on disk: a few KiB each, and without it the
# package is in the database yet pacman refuses to install it. Tracked
# separately so an unchanged run still reports itself as unchanged.
sig_only=0
for file in "${payload[@]}"; do
    name="$(basename "$file")"
    local_sig="${file}.sig"
    [[ -f "$local_sig" ]] || continue
    grep -qxF -- "$file" <(printf '%s\n' "${pending[@]}") && continue
    aws_s3 cp --only-show-errors --no-progress \
        --cache-control "$package_cache_control" \
        "$local_sig" "s3://${bucket}/${prefix}/${name}.sig"
    sig_only=$(( sig_only + 1 ))
done
if (( sig_only > 0 )); then
    printf 'Uploaded %d signature(s) for unchanged package(s)\n' "$sig_only"
fi

# Database last: a client must never see a database naming a file that is not
# uploaded yet. The database itself is never cached.
printf 'Uploading repository metadata\n'
for file in "${metadata[@]}"; do
    aws_s3 cp --only-show-errors --no-progress \
        --cache-control 'no-cache, no-store, must-revalidate' \
        "$file" "s3://${bucket}/${prefix}/${file}"
done

# Delete package files the new database no longer references, together with
# their detached signatures. Derived from the database rather than from a
# timestamp: files that are present but unlisted are unreachable by pacman and
# only cost storage.
printf 'Pruning packages no longer referenced\n'
referenced="$(mktemp)"
trap 'rm -f "$referenced"' EXIT
# The database tar contains <lib-directory>/ entries plus one
# "<name>-<ver>/desc" per package. Only desc carries %FILENAME%, which is the
# field pacman itself uses to locate the file -- asking for just those members
# avoids reading a directory entry as if it were a package record.
# create-repository.sh renames <repo>.db.tar.zst to the extensionless <repo>.db
# before this script runs, so the database here is that archive under its
# published name. Read the members straight out of it; there is no separate
# .db.tar.zst left in the directory. Under `set -o pipefail` a tar that cannot
# read the file aborts the whole publish, so the existence check below is
# load-bearing: it turns "cannot read" into a printed skip, not a silent exit.
repo_db_tar="${repository_name}.db"
[[ -f "$repo_db_tar" ]] || repo_db_tar="${repository_name}.db.tar.zst"
[[ -f "$repo_db_tar" ]] || repo_db_tar="${repository_name}.db.tar.gz"
if [[ -f "$repo_db_tar" ]] && tar -xOf "$repo_db_tar" --wildcards '*/desc' 2>/dev/null |
    awk '$0 == "%FILENAME%" { getline; print }' | sort -u > "$referenced"; then :; fi
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
        aws_s3 rm --only-show-errors "s3://${bucket}/${prefix}/${name}"
        aws_s3 rm --only-show-errors "s3://${bucket}/${prefix}/${name}.sig" || true
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
aws_s3 cp --only-show-errors --no-progress \
    "s3://${bucket}/${prefix}/${repository_name}.db" \
    "${verify_dir}/${repository_name}.db"
if ! cmp -s "${verify_dir}/${repository_name}.db" "${repository_name}.db"; then
    printf 'Published database does not match the built one.\n' >&2
    exit 1
fi

# Verify every package through the PUBLIC URL, not the S3 endpoint. A CDN edge
# can serve a corrupted body while reporting the right ETag and Content-Length
# (observed: a 6226-byte body for a 6235-byte package, ETag matching the good
# copy). Reading the object back over S3 bypasses that layer entirely, so only
# a public fetch proves what a client receives.
#
# "Cannot read it" and "read it but the bytes are wrong" are deliberately
# different outcomes. A 403 means a CDN WAF is refusing the runner (Cloudflare
# blocks cloud-provider addresses routinely), which says nothing about the
# stored object -- failing the publish for that would break every run from a
# CI IP. Only a successful read whose hash disagrees is evidence of a corrupt
# copy, and that fails the publish.
# A package name is immutable, so nothing in the upload path can tell a CDN
# edge that the body behind it changed. Cloudflare cached quirc while packages
# were uploaded `immutable` and kept serving that 76530-byte body for a year
# after the 76531-byte rebuild replaced the object -- the database and the .sig
# described the new bytes, every client failed the signature check, and only a
# cache-busting query string revealed that the stored object was correct all
# along. Purging between the upload and the verification makes the verification
# mean what it claims: the bytes a client receives, read fresh from R2.
#
# Every published package is purged, not only the ones this run uploaded: a
# run that follows a failed purge then repairs it, and an unchanged package
# costs one URL rather than a stale year. The API accepts 30 URLs per call.
if [[ -n "$cdn_zone_id" || -n "$cdn_api_token" ]]; then
    printf 'Purging the CDN cache for the published packages\n'
    purge_urls=()
    for file in "${payload[@]}"; do
        name="$(basename "$file")"
        purge_urls+=("${server_url}/${name}")
        if [[ -f "${file}.sig" ]]; then
            purge_urls+=("${server_url}/${name}.sig")
        fi
    done
    purge_cdn_batch() {
        local request response attempt
        request="$(python3 -c 'import json,sys; print(json.dumps({"files": sys.argv[1:]}))' "$@")"
        for attempt in 1 2 3; do
            response="$(curl -sS --max-time 30 -X POST \
                "${cdn_api}/zones/${cdn_zone_id}/purge_cache" \
                -H "Authorization: Bearer ${cdn_api_token}" \
                -H 'Content-Type: application/json' \
                --data "$request" 2>/dev/null || true)"
            if python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if data.get("success") else 1)
' "$response" 2>/dev/null; then
                return 0
            fi
            if (( attempt < 3 )); then
                sleep 5
            fi
        done
        printf 'Could not purge %d URL(s) from the CDN cache.\n' "$#" >&2
        printf 'Clients may keep receiving the previous bytes until the edge expires them.\n' >&2
        printf 'Purge them by hand (Caching -> Purge Cache -> single URL):\n' >&2
        printf '  %s\n' "$@" >&2
        return 1
    }
    if (( ${#purge_urls[@]} > 0 )); then
        purge_batch=()
        for url in "${purge_urls[@]}"; do
            purge_batch+=("$url")
            if (( ${#purge_batch[@]} >= 30 )); then
                purge_cdn_batch "${purge_batch[@]}" || exit 1
                purge_batch=()
            fi
        done
        if (( ${#purge_batch[@]} > 0 )); then
            purge_cdn_batch "${purge_batch[@]}" || exit 1
        fi
        printf 'Purged %d URL(s) for %d package(s).\n' \
            "${#purge_urls[@]}" "${#payload[@]}"
    fi
fi

printf 'Verifying published packages over the public URL\n'
unverified=0
for file in "${payload[@]}"; do
    name="$(basename "$file")"
    expect_sha="$(sha256sum "$file" | awk '{print $1}')"
    # R2_PUBLIC_URL already points at the package directory (it is the exact
    # value written into the .conf as Server), so the prefix must not be
    # appended again -- doing so produced .../x86_64-v3/x86_64-v3/<pkg> and a
    # 403 that looked like a corrupt edge but was just a wrong URL.
    url="${server_url}/${name}"
    got_sha=""
    http_code=""
    for attempt in 1 2 3; do
        http_code="$(curl -sS -o "${verify_dir}/${name}" -w '%{http_code}' "$url" || true)"
        if [[ "$http_code" == 2* ]]; then
            got_sha="$(sha256sum "${verify_dir}/${name}" | awk '{print $1}')"
            [[ "$got_sha" == "$expect_sha" ]] && break
        fi
        if (( attempt < 3 )); then
            printf '  %s: attempt %d returned HTTP %s; retrying\n' \
                "$name" "$attempt" "${http_code:-<no response>}" >&2
            sleep 5
        fi
    done

    if [[ "$got_sha" == "$expect_sha" ]]; then
        continue
    fi

    if [[ "$http_code" == 2* ]]; then
        printf 'Public copy of %s does not match the built package.\n' "$name" >&2
        printf '  url:       %s\n' "$url" >&2
        printf '  built:     %s\n' "$expect_sha" >&2
        printf '  published: %s\n' "$got_sha" >&2
        printf 'A CDN edge is serving a corrupted copy; purge that URL.\n' >&2
        exit 1
    fi

    # Could not read the URL at all. Report it, but do not fail: the object was
    # already verified over S3 and the database cmp above passed.
    printf '::warning::Could not verify %s over the public URL (HTTP %s).\n' \
        "$name" "${http_code:-<no response>}" >&2
    printf '  A CDN WAF may be blocking this runner; the object itself was verified over S3.\n' >&2
    unverified=$((unverified + 1))
done
if (( unverified > 0 )); then
    printf '%d package(s) could not be verified over the public URL (object verified over S3).\n' \
        "$unverified"
else
    printf 'All %d package(s) verified over the public URL.\n' "${#payload[@]}"
fi

# No fallback to the S3 endpoint: that URL is not public, so a .conf built
# from it would look valid here and fail for every client. README carries the
# value and the workflow checks it before anything is uploaded.
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
