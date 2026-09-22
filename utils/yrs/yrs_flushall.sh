# user_rowstore_flush.sh
#
# Flush user rowstore tables collecting rowstore stats before and after.
#
#
# Prerequisites:
# . Must be run as a superuser
# . If not run from the manager node the YBHOST, YBUSER, and YBPASWORD
#   env variables need to be set. These can be set on invocation. i.e.:
#      YBHOST=yb70i1 ./user_rowstore_flush_all.sh
#
# Revision History:
# 2026.09.22 (rek) - . Add -R|--no_report and -t|--trim options
#                      NOTE: default is now to not automatically trim unused yrs files after the flush.
#                    . validate yrs_flush_tables.sh found and executable
# 2026.04.06 (rek) - Add -r | --report_only option.
# 2026.04.02 (rek) - Add handling for CN where yflush needs to run on the system cluster.
# 2026.03.13 (rek) - Updates for when running from apliance manager node.
#                    Output dir changed to ../output/script_name_"$( date +"%Y%m%d_%H%M" )
# 2026.03.09 (EM)  - Error checks and notification for ybsql
# 2026.02.05 (rek) - Add yb_yrs_delete_unused_files after flush.
# 2026.02.05 (rek) - Major refactoring to support
#                    . output dirs
#                    . addl yrs queries
#                    . flush of system tables
# 2026.01.22 (rek) - updated script names and output dir.
# 2024.09.03 (rek) - Initial version.
#
# TODO:
# . Refactor for global vars set by common scripts
#

###############################################################################
# EXTERNAL COMMON FUNCTIONS
###############################################################################
source ../common/connection_fns.sh

###############################################################################
# READONLY VARIABLES
###############################################################################

readonly script_version='2026.09.22.1100'
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_file_name="$(echo $(basename $0))"
readonly script_name="$(echo $(basename $0) | cut -f1 -d'.' )"
readonly ybd_path="/mnt/ybdata/ybd/"
readonly ybsql_cmd="ybsql -X -d yellowbrick "
readonly ybsql_qat="${ybsql_cmd} -XqAt  -P footer=off "
readonly outdir="../output/${script_name}_"$( date +"%Y%m%d_%H%M" )
readonly outfile="${outdir}/${script_name}.out"
readonly hr='___________________________________________________________________'
readonly hr2='=================================================================='
readonly prop_name_width=28


###############################################################################
# FUNCTIONS
###############################################################################


function die()
#------------------------------------------------------------------------------
# Print a message to stderr and then exit the script
#
# $1 - The message to print
# $2 - Optional exit code; default 1
#------------------------------------------------------------------------------
{	# This expects 1 or 2 args only where the second is the return code.

   local _ret_cod=${2:-1}

   echo -e "$1"  1>&2
   echo ""
   exit ${_ret_code}
}


function print_section_hdr()
#------------------------------------------------------------------------------
# Print property "section" heading name, upper case, in brackets enclosed between
#   dotted lines.
# Args:
#   $1 _section - The section name
# Uses:
#   prop_name_width - global readonly variable for width of prop/section name field.
# Outputs:
#   Formatted property name its value to std out.
#   TODO: Warnng message if threshold is exceeded
#------------------------------------------------------------------------------
{
  local _section_name=$(echo $1 | tr 'a-z ' 'A-Z_')

  echo ""
  echo "${hr2}"
  echo "[${_section_name}]"
  #echo "${hr}"
}

function print_property()
#------------------------------------------------------------------------------
# Print formatted property name and its value. (Replaces spaces in name with '_').
# Args:
#   $1 _prop - The property name
#   $2 _val  - The property value
#   TODO: $3 _limit - (optl) Warning threshold as a numeric value.
# Uses:
#   prop_name_width - global readonly variable for width of prop/section name field.
# Outputs:
#   Formatted property name its value to std out.
#   TODO: Warnng message if threshold is exceeded
#------------------------------------------------------------------------------
{
  local _prop="$1"
  local _val="$2"
  local _limit="$3"
  local _pad_char='.'

  printf "%-${prop_name_width}.${prop_name_width}s" "${_prop//$_pad_char/ }" | tr ' ' "${_pad_char}"
  printf ': '"${_val}"
  printf "\n"
}



function usage()
#------------------------------------------------------------------------------
# Help/usage text
#------------------------------------------------------------------------------
{
    echo "${script_file_name}:"
    echo ". Report on or flush the Yellowbrick RowStore (yrs, a.k.a. the 'user rowstore')."
    echo ""
    echo "Usage:  ${script_file_name} [-?|r|R|t]"
    echo "   [ -r | --report_only    ] Only display the YRS reports. Does not flush the YRS."
    echo "   [ -R | --no_report      ] Do not display the YRS reports after the flush."
    echo "   [ -t | --trim           ] Trim (delete) unused YRS files after the flush."
    echo "   [ ?  | --help | --usage ] display this help message and exit"
    echo ""
    echo "Examples:"
    echo "   ${script_file_name}"
    echo "   ${script_file_name} --report_only"
    echo "   ${script_file_name} --trim"
    echo "   ${script_file_name} --no_report --trim"
    echo "   YBHOST=yb001 YBUSER=yellowbrick YBPASSWORD='yellowbrick' ${script_file_name} -r"
    echo ""
    echo "Prerequisites:"
    echo ". If not running from the manager node as the user ybdadmin, "
    echo "  . The YB* env vars must be set."
    echo "  . Must be run as a database superuser."
    echo ""
    echo "Version:"
    echo ". ${script_version}"
    echo ""
}


function get_opts()
#------------------------------------------------------------------------------
# Process command line arguments
# $1 - The args array. i.e. "$@"
#------------------------------------------------------------------------------
{
	while [[ $# > 0 ]]
	do
		opt="$1"
		case $opt in
			-r|--report_only)
				opt_report_only='t'
				;;
			-R|--no_report)
				opt_no_report='t'
				;;
			-t|--trim)
				opt_trim='t'
				;;
			-?|--help|--usage)
				usage
				exit 0;
				;;
			*)
				die "FATAL: Unknown option '$1'. Use ${SCRIPT_FILENAME} --help for usage." 1
				;;
		esac
		shift
	done
}


function run_yrs_queries()
#------------------------------------------------------------------------------
# Run the yrs state SQL queries.
#   . yrs_file_type_smry.sql - yrs flushed, unflushed, and commmit file summary.
# Args:
#   none
# Outputs:
#   Each of the yrs queries to stdout.
# Affects:
#   none
#------------------------------------------------------------------------------
{
  print_property 'yrs_query' 'yrs_file_smry.sql'
  ${ybsql_cmd} -f yrs_file_smry.sql
  print_property 'yrs_query' 'yrs_status_smry.sql'
  ${ybsql_cmd} -f yrs_status_smry.sql
  print_property 'yrs_query' 'yrs_file_type_smry.sql'
  ${ybsql_cmd} -f yrs_file_type_smry.sql
  print_property 'yrs_query' "yrs_tables.sql output to ${outdir}/yrs_tables.sql.out"
  ${ybsql_cmd} -f yrs_tables.sql -o "${outdir}/yrs_tables.sql.out"
}


###############################################################################
# MAIN
###############################################################################

function main()
{
  local rc=-1
  local yb_ver_num=0
  local is_cn="f"
  local default_cluster="none"
  local system_cluster="none"

  print_section_hdr "script"
  print_property "script_file_name" "${script_file_name}"
  print_property "start_time" $( date +"%Y.%m.%d_%H%M" )
  print_property "${script_file_name} version" "${script_version}"
  print_property "script_dir" "${script_dir}"
  print_property "outdir" "${outdir}"

  # Do validation and get needed properties from cluster
  [[ -x "${script_dir}/yrs_flush_tables.sh" ]] || die "FATAL: ${script_dir}/yrs_flush_tables.sh does not exist or is not executable." 1

  do_connect -X -d yellowbrick
  rc=$?
  sleep 1
  [[ ${rc} -eq 0 ]] || die "FATAL: Failed to connect to Yellowbrick instance." 1
  print_property "connection" "success"

  yb_ver_num="$(get_yb_ver_num -X )"
  [[ $? -eq 0 ]] || die "FATAL: Failed to get Yellowbrick server version number." 1
  print_property "yb_ver_num" "${yb_ver_num}"

  # Only CN and YB appliances > Ver 7 have default and system cluster
  if [[ ${yb_ver_num} -ge 70000 ]]; then

    system_cluster="$(get_system_cluster -X)"
    [[ $? -eq 0 ]] || die "FATAL: Failed to get system_cluster." 1
    export YBCLUSTER="${system_cluster}"

    default_cluster="$(get_default_cluster -X)"
    [[ $? -eq 0 ]] || die "FATAL: Failed to get default cluster." 1

    is_cn="$(is_cn -X )"
    [[ $? -eq 0 ]] || die "FATAL: Failed to get is_cn." 1
  fi

  print_property "system_cluster" "${system_cluster}"
  print_property "default_cluster" "${default_cluster}"
  print_property "is_cn" "${is_cn}"

  # Print the yrs reports unless -R|--no_report is specified.
    if [[ -z ${opt_no_report} ]]; then
      print_section_hdr "yrs reports"
      run_yrs_queries
    fi

  # Do the actual flushes
  if [[ -z ${opt_report_only} ]]; then

    print_section_hdr "Flush yrs user tables"
    ./yrs_flush_tables.sh "user" "${outdir}"
    print_section_hdr "Flush yrs sys tables"
    ./yrs_flush_tables.sh "sys"  "${outdir}"

    if [[ -n ${opt_trim} ]]; then
      print_section_hdr "Trim yrs files"
      ${ybsql_cmd} -c "SELECT yb_yrs_delete_unused_files()"
    fi

    if [[ -z ${opt_no_report} ]]; then
      print_section_hdr "yrs reports after yflush"
      run_yrs_queries
    fi
  fi

  print_section_hdr "DONE"
  print_property "output_file"  "${outfile}"
  echo "${hr2}"
  echo ""
}

###############################################################################
# BODY
###############################################################################

get_opts "$@"
mkdir -p ${outdir} > /dev/null || die "Failed to create out directory ${outdir}. Exiting." 1
main | tee ${outfile}

if grep -Fwq ERROR "${outfile}" ; then
  echo -e "--- \033[0;91mErrors\033[0m found in ${outfile} ---"
  grep -Fw ERROR "${outfile}"
fi
