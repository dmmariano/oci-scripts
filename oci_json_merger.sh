#!/bin/bash
#************************************************************************
#
#   oci_json_merger.sh - Merge all OCI json exports generated by 
#   exporter into one.
#
#   Copyright 2018  Rodrigo Jorge <http://www.dbarj.com.br/>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
#************************************************************************
# Available at: https://github.com/dbarj/oci-scripts
# Created on: Aug/2018 by Rodrigo Jorge
# Version 1.05
#************************************************************************
set -e

# Define paths for oci-cli and jq or put them on $PATH. Don't use relative PATHs in the variables below.
v_jq="jq"

# If MERGE_UNIQUE variable is undefined, change to 1.
# 0 = Output JSON will be simply merged.
# 1 = Output JSON will be returned in sorted order, with duplicates removed.

[[ "${MERGE_UNIQUE}" == "" ]] && MERGE_UNIQUE=1

if [ -z "${BASH_VERSION}" -o "$BASH" != "/bin/bash" ]
then
  >&2 echo "Script must be executed in BASH shell."
  exit 1
fi

function echoError ()
{
   (>&2 echo "$1")
}

function exitError ()
{
   echoError "$1"
   exit 1
}

if [ $# -ne 2 ]
then
  echoError "$0: One argument is needed.. given: $#"
  echoError "- 1st param = Zip file name pattern"
  echoError "- 2nd param = Output Zip file name"
  exit 1
fi

v_zip_file_pattern="$1"
v_zip_file_output="$2"

[ "${MERGE_UNIQUE}" != "0" -a "${MERGE_UNIQUE}" != "1" ] && exitError "MERGE_UNIQUE must be 0 or 1. Found: ${MERGE_UNIQUE}"

v_zip_files=$(ls -1 ${v_zip_file_pattern} 2>&-) && v_ret=$? || v_ret=$?
[ $v_ret -eq 0 ] || exitError "Can't find any file with pattern ${v_zip_file_pattern}"

if ! $(which ${v_jq} >&- 2>&-)
then
  echoError "Could not find jq binary. Please adapt the path in the script if not in \$PATH."
  echoError "Download page: https://github.com/stedolan/jq/releases"
  exit 1
fi

if ! $(which zip >&- 2>&-)
then
  echoError "Could not find zip binary. Please include it in \$PATH."
  exit 1
fi

v_md5='md5sum'
if ! $(which ${v_md5} >&- 2>&-)
then
  v_md5='md5'
  if ! $(which ${v_md5} >&- 2>&-)
  then
    echoError "Could not find md5sum binary. Please include it in \$PATH."
    exit 1
  fi
  v_md5='md5 -r'
fi

function mergeJson ()
{
  set -eo pipefail # Exit if error in any call.
  [ "$#" -ne 2 -o "$1" == "" -o "$2" == "" ] && { echoError "${FUNCNAME[0]} needs 2 parameters"; return 1; }
  local v_file1 v_file2 v_comp v_chk_array
  v_file1="$1"
  v_file2="$2"
  [ -f "${v_file1}" ] || exitError "File ${v_file1} does not exist."
  [ -f "${v_file2}" ] || exitError "File ${v_file2} does not exist."
  if [ ! -s "${v_file1}" ]
  then
    cat "${v_file2}"
    return 0
  elif [ ! -s "${v_file2}" ]
  then
    cat "${v_file1}"
    return 0
  fi
  v_comp=$(${v_md5} "${v_file1}" "${v_file2}" | awk '{print $1}' | sort -u | wc -l)
  if [ ${v_comp} -eq 1 ]
  then
    cat "${v_file1}"
    return 0
  fi
  v_chk_array=$(${v_jq} -r '.data | if type=="array" then "yes" else "no" end' "${v_file1}")
  [ "${v_chk_array}" == "no" ] && { ${v_jq} '.data | {"data":[.]}' "${v_file1}" > "${v_file1}.tmp"; mv "${v_file1}.tmp" "${v_file1}"; }
  v_chk_array=$(${v_jq} -r '.data | if type=="array" then "yes" else "no" end' "${v_file2}")
  [ "${v_chk_array}" == "no" ] && { ${v_jq} '.data | {"data":[.]}' "${v_file2}" > "${v_file2}.tmp"; mv "${v_file2}.tmp" "${v_file2}"; }
  ${v_jq} 'reduce inputs as $i (.; .data += $i.data)' "${v_file1}" "${v_file2}" > merge.json
  if [ $MERGE_UNIQUE -eq 1 ]
  then
    ${v_jq} '.data | unique | {data : .}' merge.json
  else
    cat merge.json
  fi
  rm -f merge.json
  return 0
}

v_json_files=""
for v_zip_file in $v_zip_files
do
  v_this_list=$(unzip -Z -1 "${v_zip_file}" "*.json") && v_ret=$? || v_ret=$?
  [ $v_ret -eq 0 ] || exitError "Can't zip list ${v_zip_file}"
  [ -z "$v_json_files" ] && v_json_files="${v_this_list}" || v_json_files="${v_json_files}"$'\n'"${v_this_list}"
  v_json_files=$(echo "${v_json_files}" | sort -u)
done

v_output_zip="${v_zip_file_output}"

for v_json_file in $v_json_files
do
  i=1
  for v_zip_file in $v_zip_files
  do
    unzip -p "${v_zip_file}" "${v_json_file}" > "${i}.json" 2>&- || true
    if [ -s "${i}.json" ]
    then
      if [ $i -ge 2 ]
      then
        mergeJson "$((i-1)).json" "${i}.json" > "out.json" && v_ret=$? || v_ret=$?
        [ $v_ret -eq 0 ] || exitError "Can't merge ${v_json_files}"
        mv "out.json" "${i}.json"
        rm -f "$((i-1)).json"
      fi
      ((++i))
    else
      rm -f "${i}.json"
    fi
  done
  ((--i))
  mv "${i}.json" "${v_json_file}"
  zip -qm -9 "$v_output_zip" "${v_json_file}"
done

exit 0
###