#!/usr/bin/env bash
# 编译 IPK 格式插件包（适用于使用 opkg 的固件，如 Kwrt）

set -euo pipefail

if (( $# < 5 )); then
  printf 'Usage: %s <sdk-root> <output-dir> <target> <subtarget> <package>...\n' "$0" >&2
  exit 2
fi

SDK_ROOT="$(realpath "$1")"
OUTPUT_DIR="$2"
TARGET="$3"
SUBTARGET="$4"
shift 4

[[ "$TARGET" =~ ^[a-z0-9_]+$ && "$SUBTARGET" =~ ^[a-z0-9_]+$ ]] || {
  printf 'Invalid target: %s/%s\n' "$TARGET" "$SUBTARGET" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mapfile -t DISCOVERED_PACKAGES < <(
  find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name Makefile \
    -printf '%h\n' |
    sed "s#^$REPO_ROOT/##" |
    awk -F / '$1 !~ /^\./' |
    sort -u
)

declare -A DISCOVERED=()
for package in "${DISCOVERED_PACKAGES[@]}"; do
  DISCOVERED["$package"]=1
done

SELECTED_PACKAGES=("$@")
for package in "${SELECTED_PACKAGES[@]}"; do
  if [[ -z "${DISCOVERED[$package]:-}" ]]; then
    printf 'Package directory was not discovered: %s\n' "$package" >&2
    exit 1
  fi
done

if [[ ! -x "$SDK_ROOT/scripts/feeds" ]]; then
  printf 'Invalid SDK root: %s\n' "$SDK_ROOT" >&2
  exit 1
fi

package_name() {
  local package_dir="$1"
  local name
  name="$(sed -n 's/^PKG_NAME:=//p' "$REPO_ROOT/$package_dir/Makefile" | head -n1)"
  [[ -n "$name" ]] || {
    printf 'PKG_NAME not found in %s/Makefile\n' "$package_dir" >&2
    exit 1
  }
  printf '%s\n' "$name"
}

# ===== 复制插件源码到 SDK =====
for package in "${DISCOVERED_PACKAGES[@]}"; do
  source_dir="$REPO_ROOT/$package"
  target_dir="$SDK_ROOT/package/$package"
  name="$(package_name "$package")"

  [[ -f "$source_dir/Makefile" ]] || {
    printf 'Package Makefile not found: %s\n' "$source_dir/Makefile" >&2
    exit 1
  }

  rm -rf "$target_dir"
  cp -a "$source_dir" "$target_dir"

  while IFS= read -r -d '' feed_link; do
    printf 'Removing conflicting feed package: %s\n' "$feed_link"
    unlink "$feed_link"
  done < <(
    find "$SDK_ROOT/package/feeds" -mindepth 2 -maxdepth 2 -type l \
      \( -name "$package" -o -name "$name" \) -print0 2>/dev/null
  )
done

# ===== 生成 .config（关键：禁用 APK，使用 opkg/IPK）=====
{
  printf '%s\n' \
    "CONFIG_TARGET_${TARGET}=y" \
    "CONFIG_TARGET_${TARGET}_${SUBTARGET}=y" \
    'CONFIG_TARGET_MULTI_PROFILE=y' \
    'CONFIG_DEVEL=y' \
    'CONFIG_BUILD_LOG=y' \
    '# CONFIG_USE_APK is not set'

  for package in "${SELECTED_PACKAGES[@]}"; do
    name="$(package_name "$package")"
    printf 'CONFIG_PACKAGE_%s=m\n' "$name"
    if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po" ]]; then
      printf 'CONFIG_PACKAGE_luci-i18n-%s-zh-cn=m\n' "${name#luci-app-}"
    fi
  done
} > "$SDK_ROOT/.config"

make -C "$SDK_ROOT" defconfig

# ===== 编译 =====
for package in "${SELECTED_PACKAGES[@]}"; do
  make -C "$SDK_ROOT" "package/$package/clean"
  make -C "$SDK_ROOT" -j"$(nproc)" "package/$package/compile" || \
    make -C "$SDK_ROOT" -j1 "package/$package/compile" V=s
done

# ===== 收集 IPK 文件 =====
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

copy_ipk() {
  local pkg_name="$1"
  local found=0
  local source_file target_file

  while IFS= read -r -d '' source_file; do
    found=1
    target_file="$OUTPUT_DIR/$(basename "$source_file")"

    if [[ -e "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
      printf 'Conflicting IPK outputs: %s\n' "$target_file" >&2
      exit 1
    fi

    cp -p "$source_file" "$target_file"
  done < <(find "$SDK_ROOT/bin" -type f -name "${pkg_name}_*.ipk" -print0 2>/dev/null)

  # 也搜索不带版本号的命名
  while IFS= read -r -d '' source_file; do
    found=1
    target_file="$OUTPUT_DIR/$(basename "$source_file")"

    if [[ -e "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
      printf 'Conflicting IPK outputs: %s\n' "$target_file" >&2
      exit 1
    fi

    cp -p "$source_file" "$target_file"
  done < <(find "$SDK_ROOT/bin" -type f -name "${pkg_name}~*.ipk" -print0 2>/dev/null)

  if (( found == 0 )); then
    printf 'IPK output not found for package: %s\n' "$pkg_name" >&2
    printf 'Searching all .ipk files in SDK bin directory:\n' >&2
    find "$SDK_ROOT/bin" -type f -name '*.ipk' -print >&2 || true
    exit 1
  fi
}

for package in "${SELECTED_PACKAGES[@]}"; do
  name="$(package_name "$package")"
  copy_ipk "$name"
  if [[ "$name" == luci-app-* ]] && [[ -d "$REPO_ROOT/$package/po" ]]; then
    copy_ipk "luci-i18n-${name#luci-app-}-zh-cn"
  fi
done

# ===== 验证收集结果 =====
mapfile -d '' -t IPK_FILES < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.ipk' -print0 | sort -z)
(( ${#IPK_FILES[@]} > 0 )) || {
  printf 'No IPK files were collected.\n' >&2
  exit 1
}

# ===== 生成清单 =====
manifest="$OUTPUT_DIR/IPK-MANIFEST.tsv"
: > "$manifest"

for ipk_file in "${IPK_FILES[@]}"; do
  pkg_name="$(ar p "$ipk_file" control.tar.gz 2>/dev/null | tar xzO ./control 2>/dev/null | sed -n 's/^Package: //p')"
  pkg_version="$(ar p "$ipk_file" control.tar.gz 2>/dev/null | tar xzO ./control 2>/dev/null | sed -n 's/^Version: //p')"
  [[ -n "$pkg_name" && -n "$pkg_version" ]] || {
    printf 'Unable to read IPK metadata: %s\n' "$ipk_file" >&2
    exit 1
  }
  printf '%s\t%s\t%s\t%s\n' \
    "$(basename "$ipk_file")" \
    "$pkg_name" \
    "$pkg_version" \
    "$(sha256sum "$ipk_file" | cut -d' ' -f1)" \
    >> "$manifest"
done

(
  cd "$OUTPUT_DIR"
  sha256sum -- *.ipk > SHA256SUMS
)

printf 'Collected IPK files:\n'
printf '  %s\n' "${IPK_FILES[@]##*/}"
