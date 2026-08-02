#!/usr/bin/env bash

# Download one or more Fast-YCB object sequences from the IIT Dataverse.
# Run this script from any directory; sequences are extracted at the repository
# root next to README.md.
#
# Usage:
#   bash tools/download/download_dataset.sh [--force] <object_name> ...
#
# Example:
#   bash tools/download/download_dataset.sh 006_mustard_bottle_real

set -euo pipefail

server="https://dataverse.iit.it"
persistent_id="doi:10.48557/G2QJDM"
version=":latest"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dataset_root="$(cd "${script_dir}/../.." && pwd)"
download_root="${dataset_root}/.downloads"
metadata_path="${download_root}/dataset.json"
force=false
objects=()

usage() {
  cat <<EOF
Usage:
  bash tools/download/download_dataset.sh [--force] <object_name> ...

Arguments:
  object_name  One or more Fast-YCB sequence names, for example:
               006_mustard_bottle_real

Options:
  --force      Replace an existing extracted sequence after the new archive
               has been downloaded, verified, and extracted successfully
  -h, --help   Show this help

Example:
  bash tools/download/download_dataset.sh 006_mustard_bottle_real
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --force)
      force=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (( $# > 0 )); do
        objects+=("$1")
        shift
      done
      ;;
    -*)
      echo "Error: unknown option '$1'." >&2
      usage >&2
      exit 2
      ;;
    *)
      objects+=("$1")
      shift
      ;;
  esac
done

if (( ${#objects[@]} == 0 )); then
  usage >&2
  exit 2
fi

for object_name in "${objects[@]}"; do
  if [[ ! "${object_name}" =~ ^[0-9]{3}_[a-z0-9_]+$ ]]; then
    echo "Error: '${object_name}' must look like 006_mustard_bottle_real." >&2
    exit 2
  fi

  destination="${dataset_root}/${object_name}"
  if [[ -e "${destination}" && "${force}" != true ]]; then
    echo "Error: ${destination} already exists." >&2
    echo "Use --force to replace it after a successful staged download." >&2
    exit 2
  fi
done

for required_command in curl jq; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "Error: required command '${required_command}' is not installed." >&2
    exit 1
  fi
done

if ! command -v bsdtar >/dev/null 2>&1; then
  for required_command in zip unzip; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
      echo "Error: bsdtar or both zip and unzip are required." >&2
      exit 1
    fi
  done
fi

if command -v md5sum >/dev/null 2>&1; then
  calculate_md5() {
    md5sum "$1" | awk '{print $1}'
  }
elif command -v md5 >/dev/null 2>&1; then
  calculate_md5() {
    md5 -q "$1"
  }
else
  echo "Error: md5sum or md5 is required for archive verification." >&2
  exit 1
fi

mkdir -p "${download_root}"

metadata_url="${server}/api/datasets/:persistentId/versions/${version}/files?persistentId=${persistent_id}"
echo "Reading Fast-YCB dataset metadata..."
curl -fL --retry 3 --retry-delay 2 \
  "${metadata_url}" -o "${metadata_path}.tmp"
mv "${metadata_path}.tmp" "${metadata_path}"

if [[ "$(jq -r '.status // empty' "${metadata_path}")" != "OK" ]]; then
  echo "Error: IIT Dataverse returned invalid dataset metadata." >&2
  exit 1
fi

download_file() {
  local file_id="$1"
  local filename="$2"
  local expected_md5="$3"
  local expected_size="$4"
  local output_path="$5"
  local file_url="${server}/api/access/datafile/${file_id}"
  local actual_md5
  local current_size
  local range_end
  local requested_size
  local received_size
  local response_range
  local response_start
  local response_total
  local chunk_path="${output_path}.chunk"
  local headers_path="${output_path}.headers"
  local chunk_size="${FAST_YCB_DOWNLOAD_CHUNK_SIZE:-67108864}"

  if [[ ! "${expected_size}" =~ ^[0-9]+$ || expected_size -le 0 ]]; then
    echo "Error: invalid expected size for ${filename}: ${expected_size}." >&2
    exit 1
  fi
  if [[ ! "${chunk_size}" =~ ^[0-9]+$ || chunk_size -le 0 ]]; then
    echo "Error: FAST_YCB_DOWNLOAD_CHUNK_SIZE must be positive." >&2
    exit 2
  fi

  current_size=0
  if [[ -f "${output_path}" ]]; then
    current_size="$(wc -c < "${output_path}" | awk '{print $1}')"
  fi

  if (( current_size == expected_size )); then
    actual_md5="$(calculate_md5 "${output_path}")"
    if [[ "${actual_md5}" == "${expected_md5}" ]]; then
      echo "Using verified download ${filename}."
      return
    fi
    echo "Checksum mismatch in complete ${filename}; restarting it..."
    rm -f "${output_path}"
    current_size=0
  elif (( current_size > expected_size )); then
    echo "Oversized partial download ${filename}; restarting it..."
    rm -f "${output_path}"
    current_size=0
  fi

  if (( current_size > 0 )); then
    echo "Resuming ${filename} at byte ${current_size}/${expected_size}..."
  else
    echo "Downloading ${filename}..."
    : > "${output_path}"
  fi

  while (( current_size < expected_size )); do
    range_end=$((current_size + chunk_size - 1))
    if (( range_end >= expected_size )); then
      range_end=$((expected_size - 1))
    fi
    requested_size=$((range_end - current_size + 1))
    rm -f "${chunk_path}" "${headers_path}"

    if ! curl -fsSL --retry 5 --retry-delay 2 \
      --range "${current_size}-${range_end}" \
      -D "${headers_path}" "${file_url}" -o "${chunk_path}"; then
      rm -f "${chunk_path}" "${headers_path}"
      echo "Error: range download failed for ${filename}; rerun to resume at byte ${current_size}." >&2
      exit 1
    fi

    response_range="$(tr -d '\r' < "${headers_path}" | awk 'tolower($1) == "content-range:" {print $3}' | tail -n 1)"
    response_start="${response_range%%-*}"
    response_total="${response_range##*/}"
    received_size="$(wc -c < "${chunk_path}" | awk '{print $1}')"
    if [[ ! "${response_start}" =~ ^[0-9]+$ ||
          "${response_start}" != "${current_size}" ||
          "${response_total}" != "${expected_size}" ||
          ! "${received_size}" =~ ^[0-9]+$ ]] ||
       (( received_size == 0 || received_size > requested_size )); then
      rm -f "${chunk_path}" "${headers_path}"
      echo "Error: invalid byte-range response for ${filename}; partial file was preserved." >&2
      exit 1
    fi

    cat "${chunk_path}" >> "${output_path}"
    current_size=$((current_size + received_size))
    rm -f "${chunk_path}" "${headers_path}"
    printf '  %s: %d/%d bytes (%d%%)\n' \
      "${filename}" "${current_size}" "${expected_size}" \
      "$((current_size * 100 / expected_size))"
  done

  actual_md5="$(calculate_md5 "${output_path}")"
  if [[ "${actual_md5}" != "${expected_md5}" ]]; then
    rm -f "${output_path}"
    echo "Error: MD5 verification failed for ${filename}; the invalid file was removed." >&2
    exit 1
  fi
  echo "Verified ${filename}."
}

download_object() {
  local object_name="$1"
  local object_download_dir="${download_root}/${object_name}"
  local split_zip_path="${object_download_dir}/${object_name}.zip"
  local merged_zip_path="${object_download_dir}/${object_name}.merged.zip"
  local extract_dir="${object_download_dir}/extracted"
  local extracted_object_dir="${extract_dir}/${object_name}"
  local destination="${dataset_root}/${object_name}"
  local backup="${object_download_dir}/previous"
  local file_id
  local filename
  local expected_md5
  local expected_size
  local archive_part
  local file_count=0
  local split_count=0

  mkdir -p "${object_download_dir}"

  while IFS=$'\t' read -r file_id filename expected_md5 expected_size; do
    [[ -n "${file_id}" ]] || continue
    download_file "${file_id}" "${filename}" "${expected_md5}" \
      "${expected_size}" \
      "${object_download_dir}/${filename}"
    ((file_count += 1))
    if [[ "${filename}" =~ \.z[0-9][0-9]$ ]]; then
      ((split_count += 1))
    fi
  done < <(
    jq -r --arg object_name "${object_name}" '
      .data[]
      | select(
          .dataFile.filename == ($object_name + ".zip") or
          (.dataFile.filename | test("^" + $object_name + "\\.z[0-9][0-9]$"))
        )
      | [
          .dataFile.id,
          .dataFile.filename,
          (.dataFile.md5 // .dataFile.checksum.value // ""),
          (.dataFile.filesize // 0)
        ]
      | @tsv
    ' "${metadata_path}" | LC_ALL=C sort -k2,2
  )

  if (( file_count == 0 )); then
    echo "Error: '${object_name}' is not present in the Fast-YCB release." >&2
    exit 2
  fi
  if [[ ! -f "${split_zip_path}" ]]; then
    echo "Error: ${object_name}.zip is missing from the Dataverse metadata." >&2
    exit 1
  fi

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"

  if (( split_count > 0 )); then
    echo "Joining ${file_count} archive parts for ${object_name}..."
    rm -f "${merged_zip_path}"
    if command -v bsdtar >/dev/null 2>&1; then
      # libarchive reads the concatenated split stream directly. This avoids
      # the split-archive repair issue in Apple's bundled Info-ZIP tools.
      : > "${merged_zip_path}"
      for archive_part in \
        "${object_download_dir}/${object_name}".z[0-9][0-9]; do
        cat "${archive_part}" >> "${merged_zip_path}"
      done
      cat "${split_zip_path}" >> "${merged_zip_path}"
    else
      # Use the repair/copy operation expected by the upstream Fast-YCB split
      # archives, but only after every part passes its published checksum.
      zip -q -F "${split_zip_path}" --out "${merged_zip_path}"
    fi
  else
    merged_zip_path="${split_zip_path}"
  fi

  echo "Verifying and extracting ${object_name}..."
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -tf "${merged_zip_path}" >/dev/null
    bsdtar -xf "${merged_zip_path}" -C "${extract_dir}"
  else
    unzip -tq "${merged_zip_path}" >/dev/null
    unzip -q "${merged_zip_path}" -d "${extract_dir}"
  fi

  if [[ ! -d "${extracted_object_dir}/rgb" ||
        ! -d "${extracted_object_dir}/depth" ||
        ! -f "${extracted_object_dir}/cam_K.json" ||
        ! -f "${extracted_object_dir}/dope/poses.txt" ]]; then
    echo "Error: extracted ${object_name} is missing required sequence data." >&2
    exit 1
  fi

  rm -rf "${backup}"
  if [[ -e "${destination}" ]]; then
    mv "${destination}" "${backup}"
  fi

  if ! mv "${extracted_object_dir}" "${destination}"; then
    if [[ -e "${backup}" ]]; then
      mv "${backup}" "${destination}"
    fi
    echo "Error: failed to install ${object_name}." >&2
    exit 1
  fi

  rm -rf "${backup}" "${object_download_dir}"
  echo "Installed Fast-YCB sequence: ${destination}"
}

for object_name in "${objects[@]}"; do
  download_object "${object_name}"
done

rmdir "${download_root}" 2>/dev/null || true
echo "Finished ${#objects[@]} Fast-YCB sequence(s)."
