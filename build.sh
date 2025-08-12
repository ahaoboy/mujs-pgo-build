#!/usr/bin/env bash

MUJS_REPO_DEFAULT="https://github.com/ccxvii/mujs.git"
MIMALLOC_REPO_DEFAULT="https://github.com/microsoft/mimalloc.git"
WD="$(pwd)"
SRCDIR="$(pwd)/build-src"
MUJS_RELEASE="$SRCDIR/mujs/build/release/mujs"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
TRAIN_SCRIPT="$(pwd)/v8v7.js"
SAMPLES=8
PGO_ENABLED=false
MIMALLOC_ENABLED=false
EXE_NAME="mujs"
OUTDIR_NAME="dist"
ZIP_NAME="mujs-pgo"

# parse args
MUJS_REPO="$MUJS_REPO_DEFAULT"
MIMALLOC_REPO="$MIMALLOC_REPO_DEFAULT"
TARGET="UNKNOWN"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pgo)
      PGO_ENABLED=true
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        TARGET="$1"
        shift
      fi
      ;;
    --mimalloc)
      MIMALLOC_ENABLED=true
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        TARGET="$1"
        shift
      fi
      ;;
    --pgo-mimalloc)
      PGO_ENABLED=true
      MIMALLOC_ENABLED=true
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        TARGET="$1"
        shift
      fi
      ;;
    --mujs-repo)
      MUJS_REPO="$2"; shift 2 ;;
    --mimalloc-repo)
      MIMALLOC_REPO="$2"; shift 2 ;;
    -j|--jobs)
      JOBS="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--pgo|--mimalloc|--pgo-mimalloc] [custom-tag]
          [--mujs-repo <url>] [--mimalloc-repo <url>] [-j N]
  --pgo               enable PGO build path
  --mimalloc          build & link with mimalloc
  --pgo-mimalloc      enable both PGO and mimalloc
  target              target
  --mujs-repo URL     override mujs repo (default: $MUJS_REPO_DEFAULT)
  --mimalloc-repo URL override mimalloc repo (default: $MIMALLOC_REPO_DEFAULT)
EOF
      exit 0 ;;
    *)
      echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if $PGO_ENABLED && $MIMALLOC_ENABLED; then
  OUTDIR_NAME="dist-pgo-mimalloc"
  EXE_NAME="mujs-pgo-mimalloc"
elif $PGO_ENABLED; then
  OUTDIR_NAME="dist-pgo"
  EXE_NAME="mujs-pgo"
elif $MIMALLOC_ENABLED; then
  OUTDIR_NAME="dist-mimalloc"
  EXE_NAME="mujs-mimalloc"
else
  OUTDIR_NAME="dist"
  EXE_NAME="mujs"
fi

OUTDIR="$(pwd)/$OUTDIR_NAME"
OUTDIR_EXE="$OUTDIR/$EXE_NAME"

# helpers
echod() { printf '\033[1;34m%s\033[0m\n' "$*"; }
echow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
echog() { printf '\033[1;32m%s\033[0m\n' "$*"; }

run_or_die() {
  command -v "$1" >/dev/null 2>&1 || { echo >&2 "Required command '$1' not found. Install it and retry."; exit 1; }
}

cp_release(){
  rm -rf "$OUTDIR"
  mkdir "$OUTDIR"
  cp -r "$MUJS_RELEASE" "$OUTDIR_EXE"
}

compress(){
  echog "Compress $OUTDIR"
  ls -lh $OUTDIR

  cd $WD
  tar -czf ./$ZIP_NAME-${TARGET}.tar.gz -C $OUTDIR .
  ls -l ./$ZIP_NAME-${TARGET}.tar.gz
  exit
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
echod "mimalloc enabled: $MIMALLOC_ENABLED"

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

# prepare mimalloc if requested
MIMALLOC_PREFIX="$SRCDIR/mimalloc-build"
if $MIMALLOC_ENABLED; then
  for cmd in cmake "$CC"; do run_or_die "$cmd"; done
  if [[ ! -d mimalloc ]]; then
    echod "Cloning mimalloc from $MIMALLOC_REPO ..."
    git clone --depth 1 "$MIMALLOC_REPO" mimalloc
  fi
  echod "Building mimalloc (out -> $MIMALLOC_PREFIX)..."
  mkdir -p "$MIMALLOC_PREFIX"
  (cd mimalloc && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$MIMALLOC_PREFIX" && cmake --build build -j"$JOBS" && cmake --install build)
  echog "mimalloc installed to $MIMALLOC_PREFIX"
fi

# prepare build flags
COMMON_CFLAGS="-I$SRCDIR/mujs -I$SRCDIR/mujs/include"
COMMON_LDFLAGS=""
MIMALLOC_LIBS=""
if $MIMALLOC_ENABLED; then
  COMMON_CFLAGS="$COMMON_CFLAGS -I$MIMALLOC_PREFIX/include"
  COMMON_LDFLAGS="$COMMON_LDFLAGS -L$MIMALLOC_PREFIX/lib -lmimalloc"
  MIMALLOC_LIBS="-L$MIMALLOC_PREFIX/lib -lmimalloc"
fi

# build function (unchanged except using MIMALLOC_LIBS when needed)
build_mujs() {
  local stage="$1"
  local extra_cflags="$2"
  local extra_ldflags="$3"
  echod ">>> [$stage] Building mujs (CFLAGS=\"$extra_cflags\")"
  cd "$SRCDIR/mujs"
  make clean || true
  make release HAVE_READLINE=no -j"$JOBS" CC="$CC" CFLAGS="-O2 -fno-common -Wall -Wextra $COMMON_CFLAGS $extra_cflags" LDFLAGS="$COMMON_LDFLAGS $extra_ldflags" || { echo "make failed"; exit 1; }
  mkdir -p "$OUTDIR"
  local exe="mujs"
  if $IS_MSYS; then exe="mujs.exe"; fi
  cp_release
  echog "Built $OUTDIR/$exe"
  cd - >/dev/null
}

# build paths
if ! $PGO_ENABLED; then
  build_mujs "normal" "" "$MIMALLOC_LIBS"
  echog "Normal build finished. Binary: $OUTDIR/mujs"
  compress
fi

# ---------- PGO path ----------
IS_GCC=false
IS_CLANG=false
if "$CC" --version 2>/dev/null | grep -qi gcc; then IS_GCC=true; fi
if "$CC" --version 2>/dev/null | grep -qi clang; then IS_CLANG=true; fi
echod "PGO path: compiler detection: GCC=$IS_GCC  CLANG=$IS_CLANG"

if $IS_GCC; then
  build_mujs "pgo-gen" "-O2 -fprofile-generate=./pgo-data -march=native -g" ""
  echod "Running training workload..."

  for ((i=1; i<=SAMPLES; i++)); do
      echo "pgo sample $i"
      $OUTDIR_EXE "$TRAIN_SCRIPT"
  done

  build_mujs "pgo-use" "-O3 -march=native -fprofile-use=./pgo-data -flto -funroll-loops -fprofile-correction" "$MIMALLOC_LIBS"
  echog "PGO build complete: $OUTDIR_EXE"
  compress
fi

if $IS_CLANG; then
  if ! command -v llvm-profdata >/dev/null 2>&1; then
    echow "llvm-profdata not found; fallback to -O3"
    build_mujs "no-pgo-fallback" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
    exit 0
  fi
  build_mujs "clang-pgo-gen" "-O2 -fprofile-instr-generate -fcoverage-mapping -g" ""
  echod "Running training workload..."

  for ((i=1; i<=SAMPLES; i++)); do
      echo "pgo sample $i"
      $OUTDIR_EXE "$TRAIN_SCRIPT"
  done

  PROFRAW="$(find . -type f -name '*.profraw' -print -quit || true)"
  if [[ -z "$PROFRAW" ]]; then
    echow "No .profraw found; fallback to -O3"
    build_mujs "no-pgo-fallback" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
    exit 0
  fi
  PROFDATA_FILE="$(pwd)/default.profdata"
  llvm-profdata merge -o "$PROFDATA_FILE" "$PROFRAW"
  build_mujs "clang-pgo-use" "-O3 -fprofile-instr-use=$PROFDATA_FILE -flto -march=native -funroll-loops" "$MIMALLOC_LIBS"
  echog "Clang PGO build complete: $OUTDIR_EXE"
  compress
fi

echow "Unknown compiler; building with -O3"
build_mujs "fallback-opt" "-O3 -march=native -flto -funroll-loops" "$MIMALLOC_LIBS"
echog "Done."

