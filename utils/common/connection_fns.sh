# connection_fns.sh
#
# Functions:
# . show_yb_env()
# . do_connect()
# . connect_with_info()
# . is_appliance()
# . is_manager()
# . is_mgr_connection()
# . is_cn()
# . get_instance_type()
# . get_default_cluster()
# . get_system_cluster()
# . get_outdir()
# . get_yb_ver_num()
#
# Revision History:
# 2026.08.31 - Multiple edits for new functions and improvements/fixes existing ones:
#              . Add connect_with_info() (do_connect() + get_yb_ver_num() in one call). 
#              . Fix is_manager() to silence the "which: no ybcli in ..." message 
#              . Fix `which` prints to stderr when ybcli is not found.
# 2026.07.17 - Implement is_appliance() as the inverse of is_cn(); both now
#              check yb_ver_num first and short-circuit for versions <7.
# 2026.07.17 - Add show_yb_env() to print YBHOST/YBUSER/YBDATABASE and a
#              fully-masked YBPASSWORD.
# 2026.03.09 - Add additional functions for yrs CN functionality.
# 2026.03.09 - Initial version
#
# NOTE: is_appliance() and is_cn() do not check for Yellowbrick Community
# Edition.
#
# TODO:
#. Use -X if not manager node because connection props might be set in ".ybsqlrc"
#  

###############################################################################
# CONNECTION FUNCTIONS
###############################################################################


function show_yb_env()
#------------------------------------------------------------------------------
# Print the current YBHOST, YBUSER, and YBDATABASE environment variable
# values. If YBPASSWORD is set, its value is fully masked (one '*' per
# character) rather than displayed in the clear.
#
# Args:
#   none
# Outputs:
#   YBHOST, YBUSER, YBDATABASE values, and a masked YBPASSWORD (if set).
# Return Code:
#   0
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local pwd_display="UNSET"

  if [[ -n ${YBPASSWORD} ]]; then
    pwd_display=$(printf '%*s' "${#YBPASSWORD}" '' | tr ' ' '*')
  fi

  echo "YBHOST    =${YBHOST:-UNSET}"
  echo "YBUSER    =${YBUSER:-UNSET}"
  echo "YBDATABASE=${YBDATABASE:-UNSET}"
  echo "YBPASSWORD=${pwd_display}"

  return 0
}


function do_connect()
#------------------------------------------------------------------------------
# Attempt a ybsql connection using the environment plus and additional passed args.
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   IF connection fails, YB* env variables.
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local pwd_display="UNSET"
  local rc=0

  # Attempt a frontend, not backend connection. In CN a backend connection may spawn a cluster resume
  ybsql $@ -qAt -c " SELECT current_user" -o delete.me
  rc=$?

  if [[ ${rc} -ne 0 ]]; then
    if [[ "${is_manager}" == "no" ]]; then
      # If YBPASSWORD is set obfuscate it before displaying
      if [[ -n ${YBPASSWORD} ]]; then
        local pwd_len=${#YBPASSWORD}
        if (( pwd_len > 2 )); then
          local middle=$(printf '%*s' $((pwd_len-2)) '' | tr ' ' '*')
          pwd_display="${YBPASSWORD:0:1}${middle}${YBPASSWORD: -1}"
        else
          pwd_display="${YBPASSWORD}"
        fi
      fi

      echo "Using"
      echo "YBHOST    =${YBHOST:-UNSET}    "
      echo "YBUSER    =${YBUSER:-UNSET}    "
      echo "YBPASSWORD=${pwd_display}"
      echo "YBSSLMODE =${YBSSLMODE:-UNSET} "
    fi
  fi

  return ${rc}
}


function connect_with_info()
#------------------------------------------------------------------------------
# Attempt a ybsql connection (via do_connect()) and, on success, return the
# yb_server_version_num (via get_yb_ver_num()).
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   The "yb_server_version_num" property value if the connection succeeds.
#   IF connection fails, YB* env variables (from do_connect()).
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local rc=0
  local yb_ver_num="0"

  do_connect $@
  rc=$?
  [[ ${rc} -ne 0 ]] && return ${rc}

  yb_ver_num=$(get_yb_ver_num $@)
  rc=$?
  echo ${yb_ver_num}

  return ${rc}
}


function is_appliance()
#------------------------------------------------------------------------------
# Is the cluster we are connecting to a Yellowbrick appliance (as opposed to
# CloudNative). This is the inverse of is_cn(). Checks yb_ver_num first: for
# versions <7 there is no CloudNative, so this returns "t" without querying.
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   "t" or "f"
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local rc=0
  local is_appliance_conn="unknown"
  local yb_ver_num

  yb_ver_num=$(get_yb_ver_num $@)
  rc=$?
  [[ ${rc} -ne 0 ]] && return ${rc}

  if (( yb_ver_num < 70000 )); then
    echo "t"
    return 0
  fi

  # Returns 't' for TRUE and 'f' for FALSE
  is_appliance_conn=$(ybsql $@ -d yellowbrick -qAt -c "SELECT (hardware_instance_type_id = '10000000-0000-0000-0000-000000000001') AS is_appliance FROM sys.cluster  WHERE is_system_cluster =TRUE" )
  rc=$?

  echo ${is_appliance_conn}

  return ${rc}
}


function is_manager()
#------------------------------------------------------------------------------
# Is this running on a manager node.
#
# Args: 
#   none
# Outputs:
#   "t" for TRUE, "f" for 
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local ybcli_path="$(which ybcli 2>/dev/null)"

  # If ybcli is found in the path this is assumed to be an appliance manager node.
  if [ -n "${ybcli_path}" ]
  then
    echo "t" 
  else
    echo "f"
  fi
}


function is_mgr_connection()
#------------------------------------------------------------------------------
# Attempt a ybsql connection using the environment plus and additional passed 
# args to check if the connection is from the manager node as a trusted user.
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   "yes" or "no"
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local pwd_display="UNSET"
  local rc=0
  local is_manager_conn="unknown"

  # Returns 't' for TRUE and 'f' for FALSE
  is_manager_conn=$(ybsql $@ -qAt -c "SELECT ((NVL(client_hostname,'')||NVL(client_ip_address,''))='') AS is_manager_conn FROM sys.session WHERE process_id = pg_backend_pid()" )
  rc=$?

  echo ${is_manager_conn}

  return ${rc}
}


function is_cn()
#------------------------------------------------------------------------------
# Is the cluster we are connecting to an CloudNative instance. This is the
# inverse of is_appliance(). Checks yb_ver_num first: for versions <7 there
# is no CloudNative, so this returns "f" without querying.
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   "t" or "f"
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local rc=0
  local is_cn_conn="unknown"
  local yb_ver_num

  yb_ver_num=$(get_yb_ver_num $@)
  rc=$?
  [[ ${rc} -ne 0 ]] && return ${rc}

  if (( yb_ver_num < 70000 )); then
    echo "f"
    return 0
  fi

  # Returns 't' for TRUE and 'f' for FALSE
  is_cn_conn=$(ybsql $@ -d yellowbrick -qAt -c "SELECT (hardware_instance_type_id != '10000000-0000-0000-0000-000000000001') AS is_cn FROM sys.cluster  WHERE is_system_cluster =TRUE" )
  rc=$?

  echo ${is_cn_conn}

  return ${rc}
}


function get_default_cluster()
#------------------------------------------------------------------------------
# Get the default cluster name from sys.cluster
# On appliances there is only one cluster; "yellowbrick"
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   The cluster name
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local rc=0
  local default_cluster="unknown"

  default_cluster=$(ybsql $@ -d yellowbrick -qAt -c "SELECT cluster_name FROM sys.cluster WHERE is_default_cluster=TRUE" )
  rc=$?
  echo ${default_cluster}

  return ${rc}
}


function get_system_cluster()
#------------------------------------------------------------------------------
# Get the system cluster name from sys.cluster
# On appliances there is only one cluster; "yellowbrick"
#
# Args:
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   The cluster name
# Return Code:
# Return Code:
#   0 if success, 1 if error
# Affects:
#   none
#------------------------------------------------------------------------------
{
  local rc=0
  local system_cluster="unknown"

  # Returns 't' for TRUE and 'f' for FALSE
  system_cluster=$(ybsql $@ -d yellowbrick -qAt -c "SELECT cluster_name FROM sys.cluster WHERE is_system_cluster=TRUE" )
  rc=$?
  echo ${system_cluster}

  return ${rc}
}

function get_outdir()
#------------------------------------------------------------------------------
# Create the output directory for the ybcli util
#
# Args: 
#   $1 util_name (reqd) - The property name
# Outputs:
#   relative directory path based on util name and current timestamp.
# Affects:
#   Creates output directory
# Return Code:
#   0 if success, 1 if error
#------------------------------------------------------------------------------
{
  echo "not implemented"
}


function get_yb_ver_num()
#------------------------------------------------------------------------------
# Wrapper around teh "yb_server_version_num" property which is an integer 
# representation of the yb_server_version_num. i.e. 7.4.3 is 70403
#
# Args: 
#   $* (optl) - Optional args to pass to ybsql
# Outputs:
#   The "yb_server_version_num" property value.
# Affects:
#   none
# Return Code:
#   0 if success, 1 if error
#------------------------------------------------------------------------------
{
  local yb_ver_num="0"
  local rc=0

  yb_ver_num="$(ybsql $@ -d yellowbrick -qAt -c 'SHOW yb_server_version_num')"
  rc=$?
  echo ${yb_ver_num}

  return ${rc}
}
