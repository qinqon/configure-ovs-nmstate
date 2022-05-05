#!/bin/bash
set -eux
# This file is not needed anymore in 4.7+, but when rolling back to 4.6
# the ovs pod needs it to know ovs is running on the host.
touch /var/run/ovs-config-executed
NM_CONN_PATH="/etc/NetworkManager/system-connections"
# this flag tracks if any config change was made
nm_config_changed=0
MANAGED_NM_CONN_SUFFIX="-slave-ovs-clone"

get_iface_attr() {
  local iface=$1
  local attr=$2
  nmstatectl show $iface --json |jq -r --arg attr $attr '.interfaces[0][$attr]'
}

# Workaround to ensure OVS is installed due to bug in systemd Requires:
# https://bugzilla.redhat.com/show_bug.cgi?id=1888017
copy_nm_conn_files() {
  local src_path="$NM_CONN_PATH"
  local dst_path="$1"
  if [ "$src_path" = "$dst_path" ]; then
    echo "No need to copy configuration files, source and destination are the same"
    return
  fi
  if [ -d "$src_path" ]; then
    echo "$src_path exists"
    local files=("${MANAGED_NM_CONN_FILES[@]}")
    shopt -s nullglob
    files+=($src_path/*${MANAGED_NM_CONN_SUFFIX}.nmconnection $src_path/*${MANAGED_NM_CONN_SUFFIX})
    shopt -u nullglob
    for file in "${files[@]}"; do
      file=$(basename "$file")
      if [ -f "$src_path/$file" ]; then
        if [ ! -f "$dst_path/$file" ]; then
          echo "Copying configuration $file"
          cp "$src_path/$file" "$dst_path/$file"
        elif ! cmp --silent "$src_path/$file" "$dst_path/$file"; then
          echo "Copying updated configuration $file"
          cp -f "$src_path/$file" "$dst_path/$file"
        else
          echo "Skipping $file since it's equal at destination"
        fi
      else
        echo "Skipping $file since it does not exist at source"
      fi
    done
  fi
}

# Used to remove files managed by configure-ovs
rm_nm_conn_files() {
  local files=("${MANAGED_NM_CONN_FILES[@]}")
  shopt -s nullglob
  files+=(${NM_CONN_PATH}/*${MANAGED_NM_CONN_SUFFIX}.nmconnection ${NM_CONN_PATH}/*${MANAGED_NM_CONN_SUFFIX})
  shopt -u nullglob
  for file in "${files[@]}"; do
    file=$(basename "$file")
    file_path="${NM_CONN_PATH}/$file"
    if [ -f "$file_path" ]; then
      rm -f "$file_path"
      echo "Removed nmconnection file $file_path"
      nm_config_changed=1
    fi
  done
}
# Used to clone a slave connection by uuid, returns new uuid
clone_slave_connection() {
  local uuid="$1"
  local old_name
  old_name="$(nmcli -g connection.id connection show uuid "$uuid")"
  local new_name="${old_name}${MANAGED_NM_CONN_SUFFIX}"
  if nmcli connection show id "${new_name}" &> /dev/null; then
    echo "WARN: existing ovs slave ${new_name} connection profile file found, overwriting..." >&2
    nmcli connection delete id "${new_name}" &> /dev/null
  fi
  nmcli connection clone $uuid "${new_name}" &> /dev/null
  nmcli -g connection.uuid connection show "${new_name}"
}
# Used to replace an old master connection uuid with a new one on all connections
replace_connection_master() {
  local old="$1"
  local new="$2"
  for conn_uuid in $(nmcli -g UUID connection show) ; do
    if [ "$(nmcli -g connection.master connection show uuid "$conn_uuid")" != "$old" ]; then
      continue
    fi
    # make changes for slave profiles in a new clone
    local new_uuid
    new_uuid=$(clone_slave_connection $conn_uuid)
    nmcli conn mod uuid $new_uuid connection.master "$new"
    nmcli conn mod $new_uuid connection.autoconnect-priority 100
    echo "Replaced master $old with $new for slave profile $new_uuid"
  done
}
# when creating the bridge, we use a value lower than NM's ethernet device default route metric
# (we pick 48 and 49 to be lower than anything that NM chooses by default)
BRIDGE_METRIC="48"
BRIDGE1_METRIC="49"
# Given an interface, generates NM configuration to add to an OVS bridge
convert_to_bridge() {
  local iface=${1}
  local bridge_name=${2}
  local bridge_metric=${3}
  if [ "$iface" = "$bridge_name" ]; then
    # handle vlans and bonds etc if they have already been
    # configured via nm key files and br-ex is already up
    ifaces=$(ovs-vsctl list-ifaces ${iface})
    for intf in $ifaces; do configure_driver_options $intf; done
    echo "Networking already configured and up for ${bridge-name}!"
    return
  fi
  # flag to reload NM to account for all the configuration changes
  # going forward
  nm_config_changed=1
  if [ -z "$iface" ]; then
    echo "ERROR: Unable to find default gateway interface"
    exit 1
  fi
  # TODO: Missing fields may-fail, dhcp-client-id, dhcp-duid, ipv6 addr-gen-mode
  # TODO: Set ${bridge_metric} to ipv4 and ipv6 routes
  cat <<EOF | tee /run/configure-ovs-state.json
{"interfaces": [{
    "name": "${bridge_name}",
    "type": "ovs-interface",
    "state": "up",
    "mac-address": "$(get_iface_attr ${iface} mac-address)",
    "mtu": "$(get_iface_attr ${iface} mtu)",
    "ipv4": $(get_iface_attr ${iface} ipv4),
    "ipv6": $(get_iface_attr ${iface} ipv6)
  }, {
    "name": "${bridge_name}",
    "type": "ovs-bridge",
    "state": "up",
    "bridge": {
      "port": [
        {"name": "${iface}"},
        {"name": "${bridge_name}"}
      ]
    }}
]}
EOF
  nmstatectl apply /run/configure-ovs-state.json
  configure_driver_options "${iface}"
}
# Used to remove a bridge
remove_ovn_bridges() {
  bridge_name=${1}
  cat <<EOF | nmstatectl apply
interfaces:
  - name: ${bridge_name}
    type: ovs-bridge
    state: absent 
  - name: ${bridge_name}
    type: ovs-interface
    state: absent
EOF
}
# Removes any previous ovs configuration
remove_all_ovn_bridges() {
  echo "Reverting any previous OVS configuration"
  remove_ovn_bridges br-ex
  remove_ovn_bridges br-ex1
  echo "OVS configuration successfully reverted"
}
# Reloads NetworkManager if any configuration change was done
reload_nm() {
  if [ $nm_config_changed -eq 0 ]; then
    # no config was changed, no need to reload
    return
  fi
  nm_config_changed=0
  
  echo "Reloading NetworkManager after configuration changes..."
  # recycle network, so that existing profiles and priorities are re-evaluated
  nmcli network off
  # wait for no devices to show as connected
  echo "Waiting for devices to disconnect..."
  if ! timeout 60 bash -c "while nmcli -g DEVICE,STATE d | grep -v :unmanaged; do sleep 5; done"; then
    echo "Warning: NetworkManager did not disconnect all devices"
  fi
  
  # reload profiles and set networking back on
  nmcli connection reload
  nmcli network on
  
  # restart NetworkManager so that we can wait on `nm-online -s`
  systemctl restart NetworkManager
  # Wait until all profiles auto-connect
  echo "Waiting for profiles to activate..."
  if nm-online -s -t 60; then
    echo "NetworkManager has activated all suitable profiles after reload"
  else
    echo "Warning: NetworkManager has not activated all suitable profiles after reload"
  fi
  # Check if we have any type of connectivity
  if nm-online -t 0; then
    echo "NetworkManager has connectivity after reload"
  else
    echo "Warning: NetworkManager does not have connectivity after reload"
  fi
}
# Removes all configuration and reloads NM if necessary
rollback_nm() {
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  remove_all_ovn_bridges
}
# Activates a NM connection profile
activate_nm_conn() {
  local conn="$1"
  local active_state="$(nmcli -g GENERAL.STATE conn show $conn)"
  if [ "$active_state" = "activated" ]; then
    echo "Connection $conn already activated"
    return
  fi
  for i in {1..10}; do
    echo "Attempt $i to bring up connection $conn"
    nmcli conn up "$conn" && s=0 && break || s=$?
    sleep 5
  done
  if [ $s -eq 0 ]; then
    echo "Brought up connection $conn successfully"
  else
    echo "ERROR: Cannot bring up connection $conn after $i attempts"
  fi
  return $s
}
# Accepts parameters $iface_default_hint_file, $iface
# Writes content of $iface into $iface_default_hint_file
write_iface_default_hint() {
  local iface_default_hint_file="$1"
  local iface="$2"
  echo "${iface}" >| "${iface_default_hint_file}"
}
# Accepts parameters $iface_default_hint_file
# Returns the stored interface default hint if the hint is non-empty,
# not br-ex, not br-ex1 and if the interface can be found in /sys/class/net
get_iface_default_hint() {
  local iface_default_hint_file=$1
  if [ -f "${iface_default_hint_file}" ]; then
    local iface_default_hint=$(cat "${iface_default_hint_file}")
    if [ "${iface_default_hint}" != "" ] &&
       [ "${iface_default_hint}" != "br-ex" ] &&
       [ "${iface_default_hint}" != "br-ex1" ] &&
       [ -d "/sys/class/net/${iface_default_hint}" ]; then
       echo "${iface_default_hint}"
       return
    fi
  fi
  echo ""
}
# Accepts parameters $bridge_interface (e.g. ovs-port-phys0)
# Returns the physical interface name if $bridge_interface exists, "" otherwise
get_bridge_physical_interface() {
  local bridge_interface="$1"
  local physical_interface=""
  physical_interface=$(nmcli -g connection.interface-name conn show "${bridge_interface}" 2>/dev/null || echo "")
  echo "${physical_interface}"
}
# Accepts parameters $iface, $iface_default_hint_file
# Finds the default interface. If the default interface is br-ex, use that and return.
# Never use the interface that is provided inside extra_bridge_file for br-ex1.
# Never use br-ex1.
# If the default interface is not br-ex:
# Check if there is a valid hint inside iface_default_hint_file. If so, use that hint.
# If there is no valid hint, use the default interface that we found during the step
# earlier. Write the default interface to the hint file.
get_default_interface() {
  local iface=""
  local counter=0
  local iface_default_hint_file="$1"
  local extra_bridge_file="$2"
  local extra_bridge=""
  if [ -f "${extra_bridge_file}" ]; then
    extra_bridge=$(cat ${extra_bridge_file})
  fi
  # find default interface
  # the default interface might be br-ex, so check this before looking at the hint
  while [ ${counter} -lt 12 ]; do
    # check ipv4 or ipv6
    # never use the interface that's specified in extra_bridge_file
    # never use br-ex1
    export extra_bridge
    iface=$(nmstatectl show --json |jq -r --arg extra_bridge "$extra_bridge" '.routes.running | map(select(
        (.destination == "0.0.0.0/0" or .destination == "fe80::/64")
        and .["next-hop-interface"] != "br-ex1"
	and .["next-hop-interface"] != $extra_bridge))
	[0]["next-hop-interface"]')
    if [[ -n "${iface}" ]]; then
      break
    fi
    counter=$((counter+1))
    sleep 5
  done
  # if the default interface does not point out of br-ex
  if [ "${iface}" != "br-ex" ] ; then
    # determine if an interface default hint exists from a previous run
    # and if the interface has a valid default route
    iface_default_hint=$(get_iface_default_hint "${iface_default_hint_file}")
    if [ "${iface_default_hint}" != "" ] &&
       [ "${iface_default_hint}" != "${iface}" ]; then
      # start wherever count left off in the previous loop
      # allow this for one more iteration than the previous loop
      while [ ${counter} -le 12 ]; do
        # check ipv4 and ipv6
        if [ "$(nmstatectl show --json |jq --arg iface_default_hint "$iface_default_hint" '
               .routes.running[] | select((
                       .destination == "0.0.0.0/0" or .destination == "fe80::/64" )
                       and .["next-hop-interface"] == $iface_default_hint )')" != "" ]; then
          iface="${iface_default_hint}"
          break
        fi
        counter=$((counter+1))
        sleep 5
      done
    fi
    # store what was determined was the (new) default interface inside
    # the default hint file for future reference
    if [ "${iface}" != "" ]; then
      write_iface_default_hint "${iface_default_hint_file}" "${iface}"
    fi
  fi
  echo "${iface}"
}
# Used to print network state
print_state() {
  echo "Current device, connection, interface and routing state:"
  nmstatectl show
}
# Setup an exit trap to rollback on error
handle_exit() {
  e=$?
  [ $e -eq 0 ] && print_state && exit 0
  echo "ERROR: configure-ovs exited with error: $e"
  print_state
  # copy configuration to tmp
  dir=$(mktemp -d -t "configure-ovs-$(date +%Y-%m-%d-%H-%M-%S)-XXXXXXXXXX")
  nmstatectl show > "$dir"/configure-ovs-state.yaml
  echo "Copied nmstate state to $dir for troubleshooting"
  # attempt to restore the previous network state
  echo "Attempting to restore previous configuration..."
  rollback_nm
  print_state
  exit $e
}
trap "handle_exit" EXIT
# Clean up old config on behalf of mtu-migration
if [ ! -f /etc/cno/mtu-migration/config ]; then
  echo "Cleaning up left over mtu migration configuration"
  rm -rf /etc/cno/mtu-migration
fi
if ! $(rpm -qa | grep -q openvswitch); then
  echo "Warning: Openvswitch package is not installed!"
  exit 1
fi
# print initial state
print_state
if [ "$1" == "OVNKubernetes" ]; then
  # Configures NICs onto OVS bridge "br-ex"
  # Configuration is either auto-detected or provided through a config file written already in Network Manager
  # key files under /etc/NetworkManager/system-connections/
  # Managing key files is outside of the scope of this script
  # if the interface is of type vmxnet3 add multicast capability for that driver
  # REMOVEME: Once BZ:1854355 is fixed, this needs to get removed.
  function configure_driver_options {
    intf=$1
    if [ ! -f "/sys/class/net/${intf}/device/uevent" ]; then
      echo "Device file doesn't exist, skipping setting multicast mode"
    else
      driver=$(cat "/sys/class/net/${intf}/device/uevent" | grep DRIVER | awk -F "=" '{print $2}')
      echo "Driver name is" $driver
      if [ "$driver" = "vmxnet3" ]; then
        ifconfig "$intf" allmulti
      fi
    fi
  }
  ovnk_config_dir='/etc/ovnk'
  ovnk_var_dir='/var/lib/ovnk'
  extra_bridge_file="${ovnk_config_dir}/extra_bridge"
  iface_default_hint_file="${ovnk_var_dir}/iface_default_hint"
  # make sure to create ovnk_config_dir if it does not exist, yet
  mkdir -p "${ovnk_config_dir}"
  # make sure to create ovnk_var_dir if it does not exist, yet
  mkdir -p "${ovnk_var_dir}"
  # For upgrade scenarios, make sure that we stabilize what we already configured
  # before. If we do not have a valid interface hint, find the physical interface
  # that's attached to ovs-if-phys0.
  # If we find such an interface, write it to the hint file.
  iface_default_hint=$(get_iface_default_hint "${iface_default_hint_file}")
  if [ "${iface_default_hint}" == "" ]; then
    current_interface=$(get_bridge_physical_interface ovs-if-phys0)
    if [ "${current_interface}" != "" ]; then
      write_iface_default_hint "${iface_default_hint_file}" "${current_interface}"
    fi
  fi
  # delete iface_default_hint_file if it has the same content as extra_bridge_file
  # in that case, we must also force a reconfiguration of our network interfaces
  # to make sure that we reconcile this conflict
  if [ -f "${iface_default_hint_file}" ] &&
     [ -f "${extra_bridge_file}" ] &&
     [ "$(cat "${iface_default_hint_file}")" == "$(cat "${extra_bridge_file}")" ]; then
    echo "${iface_default_hint_file} and ${extra_bridge_file} share the same content"
    echo "Deleting file ${iface_default_hint_file} to choose a different interface"
    rm -f "${iface_default_hint_file}"
    rm -f /run/configure-ovs-boot-done
  fi
  # on every boot we rollback and generate the configuration again, to take
  # in any changes that have possibly been applied in the standard
  # configuration sources
  if [ ! -f /run/configure-ovs-boot-done ]; then
    echo "Running on boot, restoring previous configuration before proceeding..."
    rollback_nm
    print_state
  fi
  touch /run/configure-ovs-boot-done
  iface=$(get_default_interface "${iface_default_hint_file}" "$extra_bridge_file")
  if [ "$iface" != "br-ex" ]; then
    # Default gateway is not br-ex.
    # Some deployments use a temporary solution where br-ex is moved out from the default gateway interface
    # and bound to a different nic (https://github.com/trozet/openshift-ovn-migration).
    # This is now supported through an extra bridge if requested. If that is the case, we rollback.
    # We also rollback if it looks like we need to configure things, just in case there are any leftovers
    # from previous attempts.
    if [ -f "$extra_bridge_file" ] || [ -z "$(nmcli connection show --active br-ex 2> /dev/null)" ]; then
      echo "Bridge br-ex is not active, restoring previous configuration before proceeding..."
      rollback_nm
      print_state
    fi
  fi
  convert_to_bridge "$iface" "br-ex" "${BRIDGE_METRIC}"
  # Check if we need to configure the second bridge
  if [ -f "$extra_bridge_file" ]; then
    interface=$(head -n 1 $extra_bridge_file)
    convert_to_bridge "$interface" "br-ex1" "${BRIDGE1_METRIC}"
  fi
  # Check if we need to remove the second bridge
  if [ ! -f "$extra_bridge_file" ]; then
    remove_ovn_bridges br-ex1   	 
  fi
  # Remove bridges created by openshift-sdn
  remove_ovn_bridges br0
elif [ "$1" == "OpenShiftSDN" ]; then
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  rollback_nm
  
  # Remove bridges created by ovn-kubernetes
  remove_ovn_bridges br-int
  remove_ovn_bridges br-local
fi
