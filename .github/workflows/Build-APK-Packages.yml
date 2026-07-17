name: 编译并发布 IPK 插件包

on:
  workflow_dispatch:
  push:
    branches:
      - main

permissions:
  contents: write

concurrency:
  group: publish-ipk-packages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 360
    env:
      SDK_BASE_URL: https://downloads.immortalwrt.org/snapshots/targets/armsr/armv8
      SDK_ARCHIVE_PREFIX: immortalwrt-sdk-armsr-armv8_
    steps:
      - name: 检出插件仓库
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: 安装 SDK 依赖
        env:
          DEBIAN_FRONTEND: noninteractive
        run: |
          sudo apt-get -qq update
          sudo apt-get -qq install --no-install-recommends \
            build-essential clang flex bison g++ gawk gettext git \
            libelf-dev libncurses-dev libssl-dev python3 python3-setuptools \
            rsync swig time unzip wget xsltproc zip zlib1g-dev zstd

      - name: 维护插件源码
        run: |
          .github/scripts/fix-package-permissions.sh luci-app-homeproxy
          .github/scripts/rescan-translations.sh luci-app-homeproxy
          git diff --check || true

      - name: 确定 ImmortalWrt SDK
        id: sdk
        run: |
          sums_file="$RUNNER_TEMP/immortalwrt-sha256sums"
          curl -fsSL --retry 3 "$SDK_BASE_URL/sha256sums" -o "$sums_file"
          archive=''
          sha256=''
          while read -r sum name; do
            name="${name#\*}"
            if [[ "$name" == "$SDK_ARCHIVE_PREFIX"*'.Linux-x86_64.tar.zst' ]]; then
              archive="$name"
              sha256="$sum"
              break
            fi
          done < "$sums_file"
          if [[ -z "$archive" || -z "$sha256" ]]; then
            echo "::error::找不到 SDK 归档文件"
            exit 1
          fi
          echo "archive=$archive" >> "$GITHUB_OUTPUT"
          echo "sha256=$sha256" >> "$GITHUB_OUTPUT"

      - name: 缓存 ImmortalWrt SDK
        uses: actions/cache@v4
        with:
          path: ~/.cache/immortalwrt-sdk/armsr-armv8
          key: immortalwrt-sdk-armsr-armv8-${{ steps.sdk.outputs.sha256 }}

      - name: 下载并解压 ImmortalWrt SDK
        env:
          SDK_ARCHIVE: ${{ steps.sdk.outputs.archive }}
          SDK_SHA256: ${{ steps.sdk.outputs.sha256 }}
        run: |
          cache_dir="$HOME/.cache/immortalwrt-sdk/armsr-armv8"
          archive_path="$cache_dir/$SDK_ARCHIVE"
          extract_dir="$RUNNER_TEMP/immortalwrt-sdk"
          mkdir -p "$cache_dir"

          if [[ ! -f "$archive_path" ]] || \
             [[ "$(sha256sum "$archive_path" | cut -d' ' -f1)" != "$SDK_SHA256" ]]; then
            rm -f "$archive_path"
            curl -fL --retry 3 "$SDK_BASE_URL/$SDK_ARCHIVE" -o "$archive_path"
          fi

          echo "$SDK_SHA256  $archive_path" | sha256sum -c -
          rm -rf "$extract_dir"
          mkdir -p "$extract_dir"
          tar --zstd -xf "$archive_path" -C "$extract_dir"
          sdk_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 \
            -type d -name 'immortalwrt-sdk-*' -print -quit)"
          [[ -n "$sdk_root" ]]
          echo "SDK_ROOT=$sdk_root" >> "$GITHUB_ENV"

      - name: 缓存插件下载
        uses: actions/cache@v4
        with:
          path: ~/.cache/immortalwrt-dl/armsr-armv8
          key: immortalwrt-dl-armsr-armv8-${{ hashFiles('**/Makefile') }}
          restore-keys: |
            immortalwrt-dl-armsr-armv8-

      - name: 准备插件源
        run: |
          cache_dir="$HOME/.cache/immortalwrt-dl/armsr-armv8"
          mkdir -p "$cache_dir"
          rm -rf "$SDK_ROOT/dl"
          ln -s "$cache_dir" "$SDK_ROOT/dl"
          "$SDK_ROOT/scripts/feeds" update -a
          "$SDK_ROOT/scripts/feeds" install -a

      - name: 编译 IPK
        run: |
          .github/scripts/build-ipk-packages.sh \
            "$SDK_ROOT" \
            "$RUNNER_TEMP/ipk-output" \
            'armsr' \
            'armv8' \
            'luci-app-homeproxy'

      - name: 上传编译结果
        uses: actions/upload-artifact@v4
        with:
          name: ipk-output-armsr-armv8
          path: ${{ runner.temp }}/ipk-output
          if-no-files-found: error
          retention-days: 7

  publish:
    needs: build
    runs-on: ubuntu-24.04
    env:
      GH_TOKEN: ${{ github.token }}
      RELEASE_TAG: ipk-packages-armsr-armv8
      ARCHIVE_PREFIX: immortalwrt-ipk-packages-armsr-armv8
    steps:
      - name: 检出插件仓库
        uses: actions/checkout@v4

      - name: 下载编译结果
        uses: actions/download-artifact@v4
        with:
          name: ipk-output-armsr-armv8
          path: ${{ runner.temp }}/ipk-output

      - name: 确定 ZIP 发布号
        id: archive
        run: |
          build_date="$(TZ=Asia/Shanghai date +%Y%m%d)"
          release=1

          if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
            release_id="$(gh api \
              "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" \
              --jq '.id')"
            while IFS= read -r name; do
              if [[ "$name" =~ ^${ARCHIVE_PREFIX}-${build_date}-r([0-9]+)\.zip$ ]] &&
                 (( BASH_REMATCH[1] >= release )); then
                release=$((BASH_REMATCH[1] + 1))
              fi
            done < <(
              gh api --paginate \
                "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
                --jq '.[].name'
            )
          fi

          archive_name="${ARCHIVE_PREFIX}-${build_date}-r${release}.zip"
          {
            echo "build_date=$build_date"
            echo "release=$release"
            echo "archive_name=$archive_name"
          } >> "$GITHUB_OUTPUT"

      - name: 发布 IPK
        env:
          ARCHIVE_NAME: ${{ steps.archive.outputs.archive_name }}
        run: |
          output_dir="$RUNNER_TEMP/ipk-output"
          notes_file="$RUNNER_TEMP/ipk-release-notes.md"
          assets=()
          for f in "$output_dir"/*.ipk; do
            [[ -f "$f" ]] && assets+=("$f")
          done
          (( ${#assets[@]} > 0 ))

          {
            echo 'IPK 插件包（luci-app-homeproxy）'
            echo
            echo '平台：ARMv8 (armsr/armv8)'
            echo '架构：aarch64'
            echo '适用：Phicomm N1 / Kwrt (opkg)'
            echo "最新整合包：$ARCHIVE_NAME"
          } > "$notes_file"

          if gh release view "$RELEASE_TAG" \
            --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
            gh release upload "$RELEASE_TAG" "${assets[@]}" \
              --repo "$GITHUB_REPOSITORY" --clobber
            gh release edit "$RELEASE_TAG" \
              --repo "$GITHUB_REPOSITORY" \
              --title 'IPK 插件包 - homeproxy (ARMv8/N1)' \
              --notes-file "$notes_file" \
              --prerelease=false
          else
            gh release create "$RELEASE_TAG" "${assets[@]}" \
              --repo "$GITHUB_REPOSITORY" \
              --target "$GITHUB_SHA" \
              --title 'IPK 插件包 - homeproxy (ARMv8/N1)' \
              --notes-file "$notes_file"
          fi

      - name: 发布最新整合包
        env:
          ARCHIVE_NAME: ${{ steps.archive.outputs.archive_name }}
        run: |
          bundle_dir="$RUNNER_TEMP/all-ipk-packages"
          archive="$RUNNER_TEMP/$ARCHIVE_NAME"
          rm -rf "$bundle_dir" "$archive"
          mkdir -p "$bundle_dir"

          for f in "$RUNNER_TEMP/ipk-output"/*.ipk; do
            [[ -f "$f" ]] && cp "$f" "$bundle_dir/"
          done

          mapfile -t ipk_files < <(find "$bundle_dir" -maxdepth 1 -type f -name '*.ipk')
          (( ${#ipk_files[@]} > 0 ))
          (
            cd "$bundle_dir"
            sha256sum -- *.ipk > SHA256SUMS
            zip -9 -q "$archive" -- *.ipk SHA256SUMS
          )

          release_id="$(gh api \
            "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" \
            --jq '.id')"
          while IFS=$'\t' read -r asset_id asset_name; do
            [[ "$asset_name" == "$ARCHIVE_PREFIX-"*.zip ]] || continue
            gh api --method DELETE \
              "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
          done < <(
            gh api --paginate \
              "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
              --jq '.[] | [.id, .name] | @tsv'
          )

          gh release upload "$RELEASE_TAG" "$archive" \
            --repo "$GITHUB_REPOSITORY"
          echo "### 已发布：$ARCHIVE_NAME" >> "$GITHUB_STEP_SUMMARY"
