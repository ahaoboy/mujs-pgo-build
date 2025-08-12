#!/usr/bin/env bash
# build-mujs.sh
# Build mujs (normal) or optimized (PGO + mimalloc) on Unix and MSYS2/Windows.
# Usage:
#   ./build-mujs.sh [--opt] [--mujs-repo <url>] [--mimalloc-repo <url>]
#
set -euo pipefail

# ------- config -------
MUJS_REPO_DEFAULT="https://github.com/ccxvii/mujs.git"
MIMALLOC_REPO_DEFAULT="https://github.com/microsoft/mimalloc.git"
OUTDIR="$(pwd)/dist"
SRCDIR="$(pwd)/build-src"
MUJS_RELEASE="$SRCDIR/mujs/build/release"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
TRAIN_SCRIPT="$(pwd)/v8v7.js"
PGO_ENABLED=false
# ----------------------

# parse args
MUJS_REPO="$MUJS_REPO_DEFAULT"
MIMALLOC_REPO="$MIMALLOC_REPO_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --opt) PGO_ENABLED=true; shift ;;
    --mujs-repo) MUJS_REPO="$2"; shift 2 ;;
    --mimalloc-repo) MIMALLOC_REPO="$2"; shift 2 ;;
    -j|--jobs) JOBS="$2"; shift 2 ;;
    -h|--help) cat <<EOF
Usage: $0 [--opt] [--mujs-repo <url>] [--mimalloc-repo <url>] [-j N]
  --opt             enable PGO + mimalloc build path
  --mujs-repo URL    override mujs repo (default: $MUJS_REPO_DEFAULT)
  --mimalloc-repo URL override mimalloc repo (default: $MIMALLOC_REPO_DEFAULT)
EOF
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# helpers
echod() { printf '\033[1;34m%s\033[0m\n' "$*"; }
echow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
echog() { printf '\033[1;32m%s\033[0m\n' "$*"; }

run_or_die() {
  command -v "$1" >/dev/null 2>&1 || { echo >&2 "Required command '$1' not found. Install it and retry."; exit 1; }
}

cp_release(){
  rm -rf "$OUTDIR"
  cp -r "$MUJS_RELEASE" "$OUTDIR"
}


# detect environment
UNAME="$(uname -s || echo unknown)"
IS_MSYS=false
if [[ -n "${MSYSTEM:-}" ]] || [[ "$UNAME" =~ MINGW|MSYS|CYGWIN ]]; then
  IS_MSYS=true
fi

echod "Platform: $UNAME  (MSYS-style: $IS_MSYS)"
echod "Jobs: $JOBS"
echod "PGO enabled: $PGO_ENABLED"

# check basics
for cmd in git make awk sed; do run_or_die "$cmd"; done
# compiler: prefer gcc, else clang
CC="${CC:-$(command -v gcc || command -v clang || true)}"
if [[ -z "$CC" ]]; then
  echo "No C compiler (gcc or clang) found in PATH."
  exit 1
fi
echod "Using compiler: $CC"

# prepare directories
mkdir -p "$OUTDIR" "$SRCDIR"
cd "$SRCDIR"

# clone mujs if needed
if [[ ! -d mujs ]]; then
  echod "Cloning mujs from $MUJS_REPO ..."
  git clone --depth 1 "$MUJS_REPO" mujs
else
  echod "mujs already present, fetching latest..."
  (cd mujs && git fetch --depth=1 || true)
fi

# prepare mimalloc if needed (only when PGO/opt requested)
MIMALLOC_PREFIX="$SRCDIR/mimalloc-build"
if $PGO_ENABLED; then
  for cmd in cmake "$CC"; do run_or_die "$cmd"; done
  if [[ ! -d mimalloc ]]; then
    echod "Cloning mimalloc from $MIMALLOC_REPO ..."
    git clone --depth 1 "$MIMALLOC_REPO" mimalloc
  fi
  echod "Building mimalloc (out -> $MIMALLOC_PREFIX)..."
  mkdir -p "$MIMALLOC_PREFIX"
  (cd mimalloc && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$MIMALLOC_PREFIX" && cmake --build build -j"$JOBS" && cmake --install build)
  echod "mimalloc installed to $MIMALLOC_PREFIX"
fi

# prepare build flags
COMMON_CFLAGS="-I$SRCDIR/mujs -I$SRCDIR/mujs/include"
COMMON_LDFLAGS=""
MIMALLOC_LIBS=""
if $PGO_ENABLED; then
  # if mimalloc built, point to it
  if [[ -d "$MIMALLOC_PREFIX" ]]; then
    COMMON_CFLAGS="$COMMON_CFLAGS -I$MIMALLOC_PREFIX/include"
    COMMON_LDFLAGS="$COMMON_LDFLAGS -L$MIMALLOC_PREFIX/lib -lmimalloc"
    MIMALLOC_LIBS="-L$MIMALLOC_PREFIX/lib -lmimalloc"
  fi
fi

# build function for mujs using a simple Makefile-based build (mujs uses a small make)
build_mujs() {
  local stage="$1"   # stage name for logs
  local extra_cflags="$2"
  local extra_ldflags="$3"
  echod ">>> [$stage] Building mujs (CFLAGS=\"$extra_cflags\")"

  cd "$SRCDIR/mujs"
  # clean previous build artifacts
  make clean || true

  # mujs's top-level Makefile compiles js*.c etc; we override CC/CFLAGS/LDFLAGS
  make release HAVE_READLINE=no -j"$JOBS" CC="$CC" CFLAGS="-O2 -fno-common -Wall -Wextra $COMMON_CFLAGS $extra_cflags" LDFLAGS="$COMMON_LDFLAGS $extra_ldflags" || { echo "make failed"; exit 1; }

  # copy binary out
  mkdir -p "$OUTDIR"
  local exe="mujs"
  if $IS_MSYS; then exe="mujs.exe"; fi
  echo $(pwd)
  cp_release
  echog "Built $OUTDIR/$exe"
  cd - >/dev/null
}

# normal build (no PGO)
if ! $PGO_ENABLED; then
  build_mujs "normal" "" ""
  echog "Normal build finished. Binary: $OUTDIR/$(basename mujs)"
  exit 0
fi

# ---------- PGO-enabled path ----------
# determine compiler family
IS_GCC=false
IS_CLANG=false
if "$CC" --version 2>/dev/null | grep -qi gcc; then IS_GCC=true; fi
if "$CC" --version 2>/dev/null | grep -qi clang; then IS_CLANG=true; fi

echod "PGO path: compiler detection: GCC=$IS_GCC  CLANG=$IS_CLANG"

if $IS_GCC; then
  # GCC style PGO: -fprofile-generate -> run -> -fprofile-use
  echod "Using GCC-style PGO (fprofile-generate / fprofile-use)"

  # 1) instrumented build
  build_mujs "pgo-gen" "-O2 -fprofile-generate -march=native -g" ""

  # 2) run training workload to generate .gcda files
  echod "Running training workload to generate profile data..."
  (cd "$OUTDIR" && if $IS_MSYS; then ./mujs.exe "$TRAIN_SCRIPT"; else ./mujs "$TRAIN_SCRIPT"; fi) || true
  # run a couple more times to be safe
  (cd "$OUTDIR" && if $IS_MSYS; then ./mujs.exe "$TRAIN_SCRIPT"; else ./mujs "$TRAIN_SCRIPT"; fi) || true

  # 3) use profile to build optimized binary
  build_mujs "pgo-use" "-O3 -march=native -fprofile-use -flto -funroll-loops" "$MIMALLOC_LIBS"

  echog "PGO build complete: $OUTDIR/$(basename mujs)"
  # if mimalloc is present but not statically linked, provide a run wrapper
  if [[ -d "$MIMALLOC_PREFIX" ]]; then
    # create run wrapper for unix-like
    cat > "$OUTDIR/run-with-mimalloc.sh" <<EOF
#!/usr/bin/env bash
export LD_PRELOAD="\$LD_PRELOAD:$MIMALLOC_PREFIX/lib/libmimalloc.so"
exec "\$(dirname "\$0")/mujs" "\$@"
EOF
    chmod +x "$OUTDIR/run-with-mimalloc.sh"
    echog "Created run wrapper $OUTDIR/run-with-mimalloc.sh (uses LD_PRELOAD)"
  fi

  exit 0
fi

if $IS_CLANG; then
  echod "Attempting Clang/LLVM-style PGO (instr-generate + llvm-profdata)."
  # check llvm-profdata
  if ! command -v llvm-profdata >/dev/null 2>&1; then
    echow "llvm-profdata not found; falling back to -O3 -march=native -flto build (no PGO)."
    build_mujs "no-pgo-fallback" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
    exit 0
  fi

  # instrumented build using Clang's instr-gen
  build_mujs "clang-pgo-gen" "-O2 -fprofile-instr-generate -fcoverage-mapping -g" ""

  # run training to produce default profraw (clang emits default 'default.profraw' in cwd)
  echod "Running training workload to generate clang .profraw..."
  (cd "$OUTDIR" && if $IS_MSYS; then ./mujs.exe "$TRAIN_SCRIPT"; else ./mujs "$TRAIN_SCRIPT"; fi) || true
  (cd "$OUTDIR" && if $IS_MSYS; then ./mujs.exe "$TRAIN_SCRIPT"; else ./mujs "$TRAIN_SCRIPT"; fi) || true

  # find profraw (search the tree)
  PROFRAW="$(find . -type f -name '*.profraw' -print -quit || true)"
  if [[ -z "$PROFRAW" ]]; then
    echow "No .profraw found; skipping PGO use stage and doing -O3 fallback."
    build_mujs "no-pgo-fallback" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
    exit 0
  fi
  echod "Found profraw: $PROFRAW"

  # merge into profdata
  PROFDATA_FILE="$(pwd)/default.profdata"
  llvm-profdata merge -o "$PROFDATA_FILE" "$PROFRAW"
  echod "Merged profdata -> $PROFDATA_FILE"

  # rebuild with profile use
  build_mujs "clang-pgo-use" "-O3 -fprofile-instr-use=$PROFDATA_FILE -flto -march=native -funroll-loops" "$MIMALLOC_LIBS"

  echog "Clang PGO build complete: $OUTDIR/$(basename mujs)"
  # wrapper for mimalloc
  if [[ -d "$MIMALLOC_PREFIX" ]]; then
    cat > "$OUTDIR/run-with-mimalloc.sh" <<EOF
#!/usr/bin/env bash
export LD_PRELOAD="\$LD_PRELOAD:$MIMALLOC_PREFIX/lib/libmimalloc.so"
exec "\$(dirname "\$0")/mujs" "\$@"
EOF
    chmod +x "$OUTDIR/run-with-mimalloc.sh"
    echog "Created run wrapper $OUTDIR/run-with-mimalloc.sh (uses LD_PRELOAD)"
  fi

  exit 0
fi

# fallback if compiler unknown
echow "Unknown compiler for PGO; performing aggressive O3 build with mimalloc if available"
build_mujs "fallback-opt" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
echog "Done."
