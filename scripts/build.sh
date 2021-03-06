#!/bin/bash

set -e

# Configurable variables.
readonly BASE_URL=https://asylo.dev
readonly DOCS_URL="${BASE_URL}/docs"
readonly DOCS_DIR="_docs"
readonly SOURCES_DEFAULT=/opt/asylo/sdk

readonly TEMP_ARCHIVE_PATH=/tmp/asylo.tar.gz
# The path relative to the sources directory to a file that lists
# which proto files are public and thus need to have documentation
# generated for them.
readonly PROTO_MANIFEST_PATH=asylo/public_protos.manifest
# The path relative to the sources directory to a file that lists
# which prose markdown files
readonly DOCS_MANIFEST_DEFAULT=asylo/docs.manifest

# Derived variables.
readonly HERE=$(realpath $(dirname "$0"))
# This script expects to be in the site's scripts/ subdirectory.
readonly SITE=$(realpath "${HERE}/..")

function usage() {
  cat <<EOF
  Usage: $0 [flags] [path-to-sources]
  Flags:
    -a,--git-add         Run `git add` on all created files.
    -n,--nodocs          Run without building any documentation.
    -j,--nojekyll        Run without starting a Jekyll server in docker.
    -x,--nodoxygen       Run without building Doxygen documentation.
    -p,--noprotos        Run without build protobuf documentation.
    -m,--manifest <path> Perform relocation from a documentation manifest.
                         [default manifest path is asylo/docs.manifest]
    -h,--help            Print this message to stdout.

  The path to asylo can be a path to a .tar.gz file, an https://
  URL for a .tar.gz file, or a system directory path.
  The path default is ${SOURCES_DEFAULT}.

  This script builds an up-to-date Asylo website and serves it
  incrementally from localhost for quick development iteration.
EOF
}


NO_DOCS=
NO_JEKYLL=
NO_DOXYGEN=
NO_PROTOS=
DOCS_MANIFEST=
GIT_ADD=
readonly LONG="manifest:,nodocs,nodoxygen,nojekyll,noprotos,git-add,help"
readonly PARSED=$(getopt -o anjhxm: --long "${LONG}" -n "$(basename "$0")" -- "$@")
eval set -- "${PARSED}"
while true; do
  case "$1" in
    -a|--git-add) GIT_ADD=1; shift ;;
    -n|--nodocs) NO_DOCS=1 ; shift ;;
    -j|--nojekyll) NO_JEKYLL=1; shift ;;
    -x|--nodoxygen) NO_DOXYGEN=1; shift ;;
    -p|--noprotos) NO_PROTOS=1; shift ;;
    -m|--manifest)
      if [[ "$2" = -* ]]; then  # No argument given.
        DOCS_MANIFEST="${DOCS_MANIFEST_DEFAULT}"
        shift
      else
        DOCS_MANIFEST="$2";
        shift 2
      fi
      ;;
    -h|--help) usage ; exit 0 ;;
    --) shift ; break;;
    *) echo "Unexpected input $1"; usage; exit 1 ;;
  esac
done
ASYLO_LOCATION="$1"

# No location given. Use the default.
if [[ -z "${ASYLO_LOCATION}" ]]; then
  ASYLO_LOCATION="${SOURCES_DEFAULT}"
fi

# If the path is not an existing directory or file, treat it as a URL.
if [[ -n "${ASYLO_LOCATION}" ]] &&
   [[ ! -e "${ASYLO_LOCATION}" ]] &&
   wget -nv "${ASYLO_LOCATION}" -O "${TEMP_ARCHIVE_PATH}"; then
  ASYLO_LOCATION=${TEMP_ARCHIVE_PATH}
fi

# Decompress the given or downloaded file.
if [[ -f "${ASYLO_LOCATION}" ]]; then
  TEMP=$(mktemp -d)
  if ! tar xvf "${ASYLO_LOCATION}" -C "${TEMP}"; then
    echo "Could not decompress Asylo archive ${ASYLO_LOCATION}" >&2
    exit 1
  fi
  ASYLO_LOCATION="${TEMP}"
fi

# Given the name of a .pb.html file, extract the $location marker and then
# copy the file to that relative location in the _docs hierarchy.
function relocate_file() {
  local readonly FILENAME="$1"
  local readonly OUT_DIR="$2"
  local readonly RELATIVE_BASE_URL="$3"

  local readonly LOCATION_PREFIX="^location: ${RELATIVE_BASE_URL}"
  local readonly LOCATION_LINE=$(grep "${LOCATION_PREFIX}" "${FILENAME}")
  if [[ -z "${LOCATION_LINE}" ]]; then
      echo "No 'location:' tag in ${FILENAME}, skipping"
      return
  fi
  local readonly PREFIX_LENGTH=${#LOCATION_PREFIX}
  local readonly RELATIVE_PATH="${LOCATION_LINE:${PREFIX_LENGTH}}"
  local readonly BASENAME=$(basename "${RELATIVE_PATH}")
  local readonly DIRNAME=$(dirname "${RELATIVE_PATH}")
  mkdir -p "${OUT_DIR}/${DIRNAME}"
  local readonly OUT_PATH="${OUT_DIR}/${DIRNAME}/${BASENAME}"
  echo "Writing file ${OUT_PATH}"
  # Replace absolute paths to DOMAIN with the baseurl for <a href="">
  # and for markdown [..]()
  sed -e "s!href=\"${BASE_URL}!href=\"{{site.baseurl}}!g" \
    -e "s!\][(]${BASE_URL}!]({{home}}!g" ${FILENAME} > "${OUT_PATH}"
  # If an md file, replace header links that use _ spacing with -.
  if [[ "${FILENAME}" = *.md ]]; then
    sed -i -e ':a' -e 's/\(][(]#[^)_]*\)_/\1-/;t a' "${OUT_PATH}"
  fi

  if [[ -n "${GIT_ADD}" ]]; then
    (cd "${SITE}"; git add "${OUT_PATH}")
  fi
}

function build_proto_file_doc() {
  # Uses protoc-gen-docs from github.com/istio/tools to produce documentation
  # from comments in a .proto file.
  if [[ -z $(which protoc-gen-docs) ]]; then
    echo "ERROR: Missing the proto documentation compiler protoc-gen-docs." >&2
    return 1
  fi

  local TEMP=$(mktemp -d)
  local SOURCE="$1"
  local OUT_DIR="$2"
  local USER_FLAGS="$3"
  local FLAGS="mode=jekyll_html,camel_case_fields=false,per_file=true"
  if [[ "${USER_FLAGS}" = "pkg" ]]; then
    FLAGS=$(sed -e 's/per_file=true//' <<< "${FLAGS}")
  elif [[ -n "${USER_FLAGS}" ]] && [[ "${USER_FLAGS}" != "default" ]]; then
    FLAGS="${USER_FLAGS}"
  fi
  local CMD="protoc --docs_out=${FLAGS}:${TEMP}"
  # This assumes the .proto file is in the asylo package.
  local OUT_BASE=$(sed -e 's/\.proto$/.pb.html/' <<< $(basename "${SOURCE}"))

  ${CMD} "${SOURCE}"
  relocate_file "${TEMP}/${OUT_BASE}" "${OUT_DIR}" "${DOCS_URL}"
  rm -rf "${TEMP}"
}

function build_proto_docs() {
  # Build the protobuf documentation.
  local readonly MANIFEST="$1"
  while read path flags; do
    if [[ -n "${path}" ]]; then
        build_proto_file_doc "${path}" "${SITE}/${DOCS_DIR}" "${flags}"
    fi
  done < <(sed -e 's/#.*//' "${MANIFEST}")
}

function build_doxygen_docs() {
  # Build the C++ reference docs.
  rm -rf "${SITE}/doxygen"
  # Change SGXLoader references to the SimLoader alias.
  if which doxygen; then
    $(which doxygen) && cp -r asylo/docs/html/. "${SITE}/doxygen"
  fi
  # Find baseurl: in _config.yml to replace in links, since the Doxygen
  # html is uninterpreted by Jekyll
  local CONFIG_BASEURL=$(grep baseurl "${SITE}/_config.yml" | awk '{ print $2 }')
  if [[ "${CONFIG_BASEURL}" = "/" ]]; then
    CONFIG_BASEURL=""
  fi
  find "${SITE}/doxygen" -name '*.html' -exec sed -i \
    -e "s!href=\"${BASE_URL}!href=\"${CONFIG_BASEURL}!g" \
    -e "s/SGXLoader/SimLoader/g" {} \;
  find "${SITE}/doxygen" -name '*SGXLoader*' \
    -exec sh -c 'mv {} $(sed -e 's/SGXLoader/SimLoader/g' <<< {})' \;

  # Fix the links from the GitHub README.
  local GITHUB=https://github.com/google/asylo
  sed -i -e "s#href=\"asylo/#href=\"${GITHUB}/tree/master/asylo/#g" \
    -e "s#href=\"INSTALL\.md#href=\"${GITHUB}/blob/master/INSTALL.md#" \
    "${SITE}/doxygen/index.html"
  
  if [[ -n "${GIT_ADD}" ]]; then
    (cd "${SITE}"; git add "${SITE}/doxygen/*")
  fi
}

function build_prose_docs() {
  # Relocate the prose documentation.
  local readonly MANIFEST="$1"
  while read path outdir; do
    if [[ -n "${path}" ]]; then
        relocate_file "${path}" "${SITE}"
    fi
  done < <(sed -e 's/#.*//' "${MANIFEST}")
}

function build_docs() {
  cd "${ASYLO_LOCATION}"

  if [[ -z "${NO_DOXYGEN}" ]]; then
    build_doxygen_docs
  fi

  if [[ -z "${NO_PROTOS}" ]]; then
    build_proto_docs "${PROTO_MANIFEST_PATH}"
  fi

  if [[ -n "${DOCS_MANIFEST}" ]]; then
    if [[ -z "${NO_PROSE}" ]]; then
      build_prose_docs "${DOCS_MANIFEST}"
    fi
  fi
}

if [[ -z "${NO_DOCS}" ]]; then
  # Build documentation for the given Asylo archive.
  # An archive can be either a tag or a commit hash.
  build_docs
fi

if [[ -z "${NO_JEKYLL}" ]]; then
  # Build and serve the website locally.
  docker run --rm --label=jekyll \
    --volume=${SITE}:/srv/jekyll \
    -v ${SITE}/_site:${SITE}/_site \
    -it -p 4000:4000 \
    jekyll/jekyll:3.6.0 \
    sh -c "bundle install && rake test && bundle exec jekyll serve --incremental"
fi
