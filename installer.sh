#!/usr/bin/env bash
set -e

BINARY="blockheads_server171"

# Base libs to search for (library filename prefix) and search terms for apt
declare -A LIB_SEARCH=(
  ["libgnustep-base.so"]="libgnustep-base"
  ["libobjc.so"]="libobjc"
  ["libgnutls.so"]="libgnutls"
  ["libgcrypt.so"]="libgcrypt"
  ["libffi.so"]="libffi"
  ["libicui18n.so"]="libicu"
  ["libicuuc.so"]="libicu"
  ["libicudata.so"]="libicu"
  ["libdispatch.so"]="libdispatch"
)

# helper: run apt search and choose a candidate package name (heuristic)
find_pkg_candidate() {
  local search_term="$1"
  # try to match package names that start with the search term
  # apt search output often lists lines like: package/version ...
  pkg_candidate=$(apt search "$search_term" 2>/dev/null \
    | awk '/^([a-zA-Z0-9+_.-]+)\/[^\s]*/{print $1}' \
    | sed 's#/.*$##' \
    | grep -E "^${search_term}" \
    | grep -v -e 'dbg' -e 'doc' \
    | head -n1 || true)
  printf '%s' "$pkg_candidate"
}

# Helper: find highest versioned .so file for a base lib prefix (no ldconfig)
find_highest_version_lib() {
  local base=$1
  local dirs=("/usr/lib" "/usr/lib/x86_64-linux-gnu" "/lib" "/lib/x86_64-linux-gnu" "/usr/local/lib")
  local candidates=()
  for d in "${dirs[@]}"; do
    if [ -d "$d" ]; then
      while IFS= read -r file; do
        filename=$(basename "$file")
        if [[ "$filename" == $base* ]]; then
          candidates+=("$filename")
        fi
      done < <(find "$d" -maxdepth 1 -type f -name "$base*" 2>/dev/null || true)
    fi
  done

  if [ ${#candidates[@]} -eq 0 ]; then
    echo ""
    return
  fi

  # Sort by version number descending (strip prefix then sort -V)
  IFS=$'\n' sorted=($(for f in "${candidates[@]}"; do
    ver=${f#$base}
    ver=${ver#.}
    if [ -z "$ver" ]; then ver="0"; fi
    echo "$ver $f"
  done | sort -rV))

  echo "${sorted[0]#* }"
}

# Check if package is installed
is_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

# Install package (quiet-ish)
install_package() {
  echo "Installing package: $1"
  sudo apt-get update -y
  sudo apt-get install -y "$1"
}

# build libdispatch from source (if needed)
DIR=$(pwd)
ROOT=''
echo "Checking for superuser privileges..."
if [ "$(whoami)" != "root" ]; then
    if ! command -v sudo 2>&1 >/dev/null; then
        echo "Not running as root and sudo is not available."
        exit 1
    fi
    if ! sudo -v; then
        echo "Failed to acquire superuser privileges."
        exit 1
    fi
    ROOT='sudo'
fi

build_libdispatch() {
    if [ -d "${DIR}/swift-corelibs-libdispatch/build" ]; then
        rm -rf 'swift-corelibs-libdispatch'
    fi
    git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "${DIR}/swift-corelibs-libdispatch" || return 1
    mkdir -p "${DIR}/swift-corelibs-libdispatch/build" || return 1
    cd "${DIR}/swift-corelibs-libdispatch/build" || return 1
    cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ .. || return 1
    ninja "-j$(nproc)" || return 1
    $ROOT ninja install || return 1
    cd "${DIR}" || return 1
    # Refresh system library cache
    $ROOT ldconfig || true
}

# download binary (direct from jsdelivr)
download_binary() {
  if [ -f "$BINARY" ]; then
    echo "$BINARY already exists, skipping download."
  else
    echo "Downloading $BINARY ..."
    curl -sL -o "$BINARY" "https://cdn.jsdelivr.net/gh/NovaDev404/blockheads-server@main/blockheads_server171"
    chmod +x "$BINARY" || true
  fi
}

# core install/patch flow (your existing logic, organized into a function)
do_install() {
  download_binary

  # ensure patchelf present
  sudo apt-get update -y
  sudo apt-get install -y patchelf >/dev/null

  # Main loop: handle each lib base
  for libbase in "${!LIB_SEARCH[@]}"; do
    search_term="${LIB_SEARCH[$libbase]}"
    echo "Processing $libbase (searching apt for: $search_term)"

    # Find highest version lib file installed
    libfile=$(find_highest_version_lib "$libbase")

    # Special handling for libdispatch: if not found, attempt to build via build_libdispatch
    if [ "$libbase" = "libdispatch.so" ]; then
      if [ -n "$libfile" ]; then
        echo "Found library file $libfile (libdispatch already present)"
      else
        echo "No local $libbase found ï¿½ attempting to build libdispatch from source..."
        sudo apt-get update -y
        sudo apt-get install -y git cmake ninja-build clang build-essential pkg-config libbsd-dev || true

        if build_libdispatch; then
          echo "build_libdispatch returned success, re-checking for libdispatch..."
          libfile=$(find_highest_version_lib "$libbase")
        else
          echo "build_libdispatch failed ï¿½ libdispatch not available after build."
        fi
      fi

      if [ -z "$libfile" ]; then
        echo "Still no library file found for $libbase after build attempt, skipping patch for libdispatch."
        continue
      fi
    else
      # Non-libdispatch flow: try to find or install via apt
      if [ -z "$libfile" ]; then
        echo "No local $libbase found, searching apt packages..."
        pkg_candidate=$(find_pkg_candidate "$search_term")

        if [ -z "$pkg_candidate" ]; then
          echo "No package found for $search_term, skipping"
          continue
        fi

        if is_installed "$pkg_candidate"; then
          echo "Package $pkg_candidate already installed"
        else
          install_package "$pkg_candidate" || true
        fi

        # Re-check for library after install
        libfile=$(find_highest_version_lib "$libbase")
        if [ -z "$libfile" ]; then
          echo "Still no library file found for $libbase after installing $pkg_candidate, skipping patch"
          continue
        fi
      fi
    fi

    echo "Found library file $libfile"

    # Patch binary: replace all needed libs matching base with found version
    needed_libs=$(patchelf --print-needed "$BINARY" | grep "^$libbase" || true)
    if [ -z "$needed_libs" ]; then
      echo "No existing dependency on $libbase found in binary, skipping"
    else
      for oldlib in $needed_libs; do
        echo "Replacing needed $oldlib with $libfile"
        patchelf --replace-needed "$oldlib" "$libfile" "$BINARY"
      done
    fi
  done

  echo
  echo "Patching complete for $BINARY"
  echo "You can now run the blockheads server with ./$BINARY"
}

# uninstall helper: collect installed candidate packages (from LIB_SEARCH)
collect_installed_packages() {
  installed_pkgs=()
  libdispatch_pkg=""
  for libbase in "${!LIB_SEARCH[@]}"; do
    search_term="${LIB_SEARCH[$libbase]}"
    candidate=$(find_pkg_candidate "$search_term")
    if [ -n "$candidate" ] && is_installed "$candidate"; then
      installed_pkgs+=("$candidate")
      if [ "$libbase" = "libdispatch.so" ]; then
        libdispatch_pkg="$candidate"
      fi
    fi
  done
}

# actual uninstall flow (interactive)
do_uninstall() {
  echo "Preparing uninstall options..."
  collect_installed_packages

  # check for libdispatch file presence
  libdispatch_file=$(find_highest_version_lib "libdispatch.so" || true)
  libdispatch_present=false
  if [ -n "$libdispatch_file" ]; then
    libdispatch_present=true
  fi

  echo
  echo "Uninstall options:"
  echo "  1) everything (binary + libdispatch + installed packages: ${installed_pkgs[*]:-(none)})"
  echo "  2) only blockheads server and libdispatch"
  echo
  read -r -p "Choose uninstall scope (everything/blockheads) [blockheads]: " choice
  choice=${choice:-blockheads}
  choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

  if [ "$choice" = "everything" ]; then
    # Build comma-separated list for prompt
    if [ ${#installed_pkgs[@]} -gt 0 ]; then
      pkg_list=$(IFS=, ; echo "${installed_pkgs[*]}")
    else
      pkg_list="(no matching apt packages detected)"
    fi

    echo
    echo "This will forcefully delete: $BINARY, libdispatch, $pkg_list"
    read -r -p "Are you sure? Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
      echo "Aborting uninstall."
      exit 0
    fi

    # remove binary
    if [ -f "$BINARY" ]; then
      echo "Removing $BINARY"
      sudo rm -f "$BINARY" || true
    else
      echo "$BINARY not present, skipping removal."
    fi

    # remove libdispatch via apt if package detected
    if [ -n "$libdispatch_pkg" ] && is_installed "$libdispatch_pkg"; then
      echo "Removing package $libdispatch_pkg"
      sudo apt-get remove --purge -y "$libdispatch_pkg" || true
    else
      # remove installed libdispatch files under /usr/local/lib (best-effort)
      if $libdispatch_present; then
        echo "libdispatch files found ($libdispatch_file) ï¿½ attempting removal from /usr/local/lib"
        sudo rm -f /usr/local/lib/libdispatch* || true
        sudo ldconfig || true
      else
        echo "No libdispatch package found and no local libdispatch files detected."
      fi
    fi

    # remove other packages
    if [ ${#installed_pkgs[@]} -gt 0 ]; then
      # remove duplicates and libdispatch_pkg (already removed/purged above)
      pkgs_to_remove=()
      for p in "${installed_pkgs[@]}"; do
        if [ "$p" != "$libdispatch_pkg" ]; then
          pkgs_to_remove+=("$p")
        fi
      done

      if [ ${#pkgs_to_remove[@]} -gt 0 ]; then
        echo "Removing packages: ${pkgs_to_remove[*]}"
        sudo apt-get remove --purge -y "${pkgs_to_remove[@]}" || true
      else
        echo "No additional packages to remove."
      fi
    fi

    echo "Uninstall (everything) complete."
    exit 0

  elif [ "$choice" = "blockheads" ] || [ "$choice" = "blockheads server" ] || [ "$choice" = "blockheads_server" ]; then
    echo
    echo "This will remove $BINARY and libdispatch (if present)."
    read -r -p "Are you sure? Type 'yes' to proceed: " confirm2
    if [ "$confirm2" != "yes" ]; then
      echo "Aborting uninstall."
      exit 0
    fi

    # remove binary
    if [ -f "$BINARY" ]; then
      echo "Removing $BINARY"
      sudo rm -f "$BINARY" || true
    else
      echo "$BINARY not present, skipping removal."
    fi

    # remove libdispatch as above
    if [ -n "$libdispatch_pkg" ] && is_installed "$libdispatch_pkg"; then
      echo "Removing package $libdispatch_pkg"
      sudo apt-get remove --purge -y "$libdispatch_pkg" || true
    else
      if $libdispatch_present; then
        echo "libdispatch files found ($libdispatch_file) ï¿½ attempting removal from /usr/local/lib"
        sudo rm -f /usr/local/lib/libdispatch* || true
        sudo ldconfig || true
      else
        echo "No libdispatch package found and no local libdispatch files detected."
      fi
    fi

    echo "Uninstall (blockheads + libdispatch) complete."
    exit 0
  else
    echo "Unknown choice: $choice"
    exit 1
  fi
}

# CLI dispatch
case "$1" in
  --install) do_install ;;
  --uninstall) do_uninstall ;;
  -h|--help|"") echo "Please specify --install or --uninstall"; exit 1 ;;
  *) echo "Please specify --install or --uninstall"; exit 1 ;;
esac
