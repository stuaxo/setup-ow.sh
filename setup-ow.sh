#!/bin/bash

# At the top of the script variables are setup for get_inputs_{platform} to set.
declare -a versions=("1.8" "1.9" "2.0" "2.0-64")

# Defaults will be overidden by get_inputs
tag_default="current"
needs_chmod=false
environment=false

# Unlike the original setup-watcom the version is appended to the directory name by default.
platform=$(uname -s)
case "${platform}"
in
  "Linux") default_location="/opt/watcom$version";;
  "Darwin") echo "Unsupported platform"; exit 1;;
  "WindowsNT") default_location="C:\\watcom";;
  *) echo "Unsupported platform"; exit 1;;
esac

get_inputs() {
  # Read input parameters
  # Ported from setup-openwatcom, including -f to force download
  while getopts v:t:l:e:f option
  do
  case "${option}"
  in
  v) version=${OPTARG};;
  t) tag=${OPTARG};;
  l) location=${OPTARG};;
  e) environment=${OPTARG};;
  f) delete_flag=true;;
  *) echo "usage: $0 [-v version] [-t tag] [-l location] [-e environment]"; exit 1;;
  esac
  done

  # Check if version is allowed
  if [[ ! " ${versions[@]} " =~ " ${version} " ]]; then
    echo "version needs to be one of ${versions[@]}, got ${version}"
    exit 1
  fi

  # Define URL, archive type and other parameters based on the version
  case "${version}"
  in
  "2.0"|"2.0-64")
    tag=${tag:-$tag_default}
    declare -A tag_aliases=(["current"]="Current-build" ["last"]="Last-CI-build")
    tag=${tag_aliases[$tag]:-$tag}
    url="https://github.com/open-watcom/open-watcom-v2/releases/download/${tag}/ow-snapshot.tar"
    archive_type="tar"
    path_subdir="binl64"
    ;;
  "1.9")
    url="https://github.com/open-watcom/open-watcom-1.9/releases/download/ow1.9/open-watcom-c-linux-1.9"
    needs_chmod=true
    archive_type="exe"
    path_subdir="binl"
    ;;
  "1.8")
    url="https://github.com/open-watcom/open-watcom-1.8/releases/download/ow1.8/open-watcom-c-linux-1.8"
    needs_chmod=true
    archive_type="exe"
    path_subdir="binl"
    ;;
  esac

  # Set default location if not provided
  location=${location:-$default_location-$version}
}


download_file() {
  local delete_flag="${1:-false}"
  local url="$2"
  local filename="$3"

  # Extract filename from URL if not provided
  if [ -z "$filename" ]; then
    filename="${url##*/}"
    filename="${filename%%\?*}"
  fi

  if [ -f "$filename" ]; then
    # Retrieve remote file information
    remote_info=$(curl -sL -I "$url" | tr -d '\r')
    # Since there was a 302 redirect, there is a Content-Length: 0 need to ignore before the relevant content-length
    read -r _ remote_size <<< "$(grep -i '^Content-Length:' <<< "$remote_info" | tail -1)"
    remote_size="${remote_size##*: }"
    remote_size="${remote_size//[[:space:]]/}"
    read -r _ remote_modified <<< "$(grep -i '^last-modified:' <<< "$remote_info")"
    remote_modified="${remote_modified##*: }"
    remote_modified="${remote_modified//,/}"
    remote_timestamp=$(date -d "$remote_modified" +"%s")
    
    # Retrieve local file information
    read -r local_size _ <<< "$(stat -c '%s %n' "$filename")"
    read -r local_modified _ <<< "$(stat -c '%y %n' "$filename")"
    local_modified="${local_modified%% *}"
    local_timestamp=$(date -d "$local_modified" +"%s")
    
    # Compare file sizes and timestamps
    if [ "$remote_size" = "$local_size" ] && [ "$remote_timestamp" -le "$local_timestamp" ]; then
      echo "File already downloaded."
      return
    elif [ "$remote_size" = "$local_size" ] && [ "$remote_timestamp" -gt "$local_timestamp" ]; then
      echo "The local file is different from the remote file."
      if [ "$delete_flag" = true ]; then
        echo "Deleting the local file..."
        rm "$filename"
      fi
    fi
  fi

  # Start or continue the download
  curl -C - -L -o "${filename}.part" --progress-bar "$url"

  # Check if the download was successful
  if [ "$?" -eq 0 ]; then
     mv "${filename}.part" "$filename"
     echo "Download completed!"
  fi
}


get_inputs "$@"

filename="${url##*/}"
filename="${filename%%\?*}"
download_file "$delete_flag" "$url" "$filename"

sudo=""
if [ "$EUID" -ne 0 ]; then
  sudo="sudo"
fi

# If the archive type is exe - it is a self-extracting archive, aka a valid zip file.
echo "Unpacking $filename to $location"
if [ "$archive_type" = "exe" ]; then
  $sudo unzip -q -o "$filename" -d "${location}"
else
  $sudo tar -xf "$filename" -C "${location}"
fi

if [ "$needs_chmod" = true ]; then
  # Zip files don't (usually) preserve the executable bit so it needs to be set
  # for manually for ELF32 or ELF64 files.
  echo "Ensure executables in $location/$path_subdir are executable"
  find $location/$path_subdir -type f | while read -r file; do
    if file -b "$file" | grep -qE 'ELF 32-bit.*executable|ELF 64-bit.*executable'; then
      $sudo chmod +x "$file"
    fi
  done
fi

echo ""
# Display the environment variables that need to be set
echo "Environment variables to set:"
echo "export WATCOM=$location"
echo "export PATH=\$PATH:\$WATCOM/$path_subdir"
