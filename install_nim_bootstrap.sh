#!/bin/bash

# Puts a Nim toolchain in --install-directory, for the sole purpose of compiling
# nimble from source. It is never added to PATH -- only the nimble binary it
# produces ends up on the user's PATH.
#
# No-ops when a usable Nim is already available, so the common cases (the user
# brought their own Nim, or a previous run's toolchain was restored from cache)
# cost nothing.
#
# Binaries come from nim-lang/nightlies, which publishes prebuilt archives for
# every target we need -- including macosx_arm64 and macosx_x64, which
# nim-lang.org does not offer. That avoids a Nim source build on every platform.

set -eu

DATE_FORMAT="%Y-%m-%d %H:%M:%S"

NIGHTLIES_REPO="nim-lang/nightlies"

info() {
  echo "$(date +"$DATE_FORMAT") [INFO] $*"
}

err() {
  echo "$(date +"$DATE_FORMAT") [ERR] $*" >&2
}

api_get() {
  local url response http_code
  url=$1
  if [[ -n "$repo_token" ]]; then
    response=$(curl -sSL -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${repo_token}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url")
  else
    response=$(curl -sSL -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url")
  fi

  http_code=${response##*$'\n'}
  if [[ "$http_code" != "200" ]]; then
    return 1
  fi
  printf '%s' "${response%$'\n'*}"
}

# Maps the runner to a nightlies asset prefix, e.g. "macosx_arm64".
target_name() {
  local machine arch
  machine=$(uname -m)
  case "$machine" in
  x86_64 | amd64) arch="x64" ;;
  arm64 | aarch64) arch="arm64" ;;
  *)
    err "Unsupported architecture for a source build: ${machine}"
    exit 1
    ;;
  esac

  case "$os" in
  Windows) echo "windows_${arch}" ;;
  macOS | Darwin) echo "macosx_${arch}" ;;
  *) echo "linux_${arch}" ;;
  esac
}

# All `latest-version-N-M` rolling tags present, highest first.
available_tags() {
  printf '%s' "$1" |
    jq -r '.[].tag_name' |
    { grep -E '^latest-version-[0-9]+-[0-9]+$' || true; } |
    sed -E 's/^latest-version-([0-9]+)-([0-9]+)$/\1.\2/' |
    sort -Vr |
    sed -E 's/^([0-9]+)\.([0-9]+)$/latest-version-\1-\2/'
}

# nimble builds against Nim stable, so the bootstrap tracks the release branch
# the stable channel currently points at -- NOT simply the highest tag, which is
# a pre-release branch whenever stable has not yet been promoted to it.
# Falls back to the highest available branch if the channel cannot be read.
pick_tag() {
  local releases tags stable wanted
  releases=$1
  tags=$(available_tags "$releases")

  stable=$(curl -sSL --max-time 20 https://nim-lang.org/channels/stable 2>/dev/null |
    tr -d '[:space:]' |
    { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; })

  if [[ -n "$stable" ]]; then
    wanted="latest-version-${stable%%.*}-$(echo "$stable" | cut -d. -f2)"
    if printf '%s\n' "$tags" | grep -qx "$wanted"; then
      info "Nim stable is ${stable}; using nightlies branch ${wanted}" >&2
      printf '%s' "$wanted"
      return 0
    fi
    info "No nightlies branch for stable ${stable}; falling back to the newest branch" >&2
  fi

  printf '%s\n' "$tags" | head -n1
}

# parse commandline args
install_dir=""
os="Linux"
repo_token=""
print_tag_only="false"
tag=""

while ((0 < $#)); do
  opt=$1
  shift
  case $opt in
  --install-directory)
    install_dir=$1
    shift
    ;;
  --os)
    os=$1
    shift
    ;;
  --repo-token)
    repo_token=$1
    shift
    ;;
  # Resolves and prints the nightlies tag without downloading anything, so the
  # action can name it in a cache key before deciding to fetch.
  --print-tag)
    print_tag_only="true"
    ;;
  # A tag already resolved by --print-tag. Skips the API calls entirely.
  --tag)
    tag=$1
    shift
    ;;
  *)
    err "Unknown option '${opt}'"
    exit 1
    ;;
  esac
done

if [[ "$print_tag_only" = "true" ]]; then
  if ! releases=$(api_get "https://api.github.com/repos/${NIGHTLIES_REPO}/releases?per_page=100"); then
    err "Failed to list ${NIGHTLIES_REPO} releases"
    exit 1
  fi
  tag=$(pick_tag "$releases")
  if [[ -z "$tag" ]]; then
    err "Found no 'latest-version-*' release in ${NIGHTLIES_REPO}"
    exit 1
  fi
  printf '%s\n' "$tag"
  exit 0
fi

if [[ -z "$install_dir" ]]; then
  err "--install-directory is required"
  exit 1
fi

# Tells the action whether there is a freshly fetched toolchain worth caching.
emit_fetched() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "fetched=$1" >> "$GITHUB_OUTPUT"
  fi
}

if command -v nim > /dev/null 2>&1; then
  info "Using the nim already on PATH: $(command -v nim)"
  emit_fetched false
  exit 0
fi

if [[ -x "${install_dir}/bin/nim" || -x "${install_dir}/bin/nim.exe" ]]; then
  info "Using the cached bootstrap Nim in ${install_dir}"
  emit_fetched false
  exit 0
fi

target=$(target_name)
info "Fetching a bootstrap Nim for ${target}..."

if [[ -z "$tag" ]]; then
  if ! releases=$(api_get "https://api.github.com/repos/${NIGHTLIES_REPO}/releases?per_page=100"); then
    err "Failed to list ${NIGHTLIES_REPO} releases"
    exit 1
  fi
  tag=$(pick_tag "$releases")
  if [[ -z "$tag" ]]; then
    err "Found no 'latest-version-*' release in ${NIGHTLIES_REPO}"
    exit 1
  fi
fi

# Asset names are fixed per target, so the URL can be built without asking the
# API for it; a wrong guess fails loudly at the checked download below.
ext="tar.xz"
if [[ "$target" = windows_* ]]; then
  ext="zip"
fi
download_url="https://github.com/${NIGHTLIES_REPO}/releases/download/${tag}/${target}.${ext}"

info "Bootstrap Nim: ${tag} (${target})"
info "Downloading from: ${download_url}"

# Everything happens in a staging directory that is moved into place only once
# the toolchain is verified complete. The install directory therefore never
# exists in a partial state -- which matters because the action caches it, and
# a cache key is immutable: a half-extracted toolchain saved once would be
# restored on every later run for as long as the entry lived.
staging="${install_dir}.unpack"
rm -rf "$staging"
mkdir -p "$staging"

archive="${staging}/nim.${ext}"
# Downloaded as a separate, checked step rather than piped into tar: in a
# pipeline only tar's exit status is visible, and tar on empty input can exit 0.
if ! curl -fsSL "$download_url" -o "$archive"; then
  err "Failed to download ${download_url}"
  rm -rf "$staging"
  exit 1
fi

unpacked="${staging}/nim"
mkdir -p "$unpacked"
if [[ "$ext" = "zip" ]]; then
  unzip -q "$archive" -d "$unpacked"
  # The zip wraps everything in a single nim-<version> directory.
  inner=$(find "$unpacked" -mindepth 1 -maxdepth 1 -type d | head -n1)
  if [[ -z "$inner" ]]; then
    err "Unexpected archive layout in ${download_url}"
    rm -rf "$staging"
    exit 1
  fi
  unpacked="$inner"
else
  # tar autodetects xz here, which keeps this working with both GNU tar and the
  # bsdtar that ships on macOS.
  tar xf "$archive" -C "$unpacked" --strip-components=1
fi

if [[ ! -x "${unpacked}/bin/nim" && ! -x "${unpacked}/bin/nim.exe" ]]; then
  err "Bootstrap Nim was unpacked but bin/nim is missing"
  rm -rf "$staging"
  exit 1
fi

rm -rf "$install_dir"
mv "$unpacked" "$install_dir"
rm -rf "$staging"

emit_fetched true
info "Bootstrap Nim ready in ${install_dir}"
