#!/bin/bash
set -eux
# This file is not needed anymore in 4.7+, but when rolling back to 4.6
# the ovs pod needs it to know ovs is running on the host.
touch /var/run/ovs-config-executed
NM_CONN_PATH="/etc/NetworkManager/system-connections"
# this flag tracks if any config change was made
nm_config_changed=0
MANAGED_NM_CONN_SUFFIX="-slave-ovs-clone"
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
update_nm_conn_files() {
  bridge_name=${1}
  port_name=${2}
  ovs_port="ovs-port-${bridge_name}"
  ovs_interface="ovs-if-${bridge_name}"
  default_port_name="ovs-port-${port_name}" # ovs-port-phys0
  bridge_interface_name="ovs-if-${port_name}" # ovs-if-phys0
  # In RHEL7 files in /{etc,run}/NetworkManager/system-connections end without the suffix '.nmconnection', whereas in RHCOS they end with the suffix.
  MANAGED_NM_CONN_FILES=($(echo {"$bridge_name","$ovs_interface","$ovs_port","$bridge_interface_name","$default_port_name"} {"$bridge_name","$ovs_interface","$ovs_port","$bridge_interface_name","$default_port_name"}.nmconnection))
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
  local port_name=${3}
  local bridge_metric=${4}
  local ovs_port="ovs-port-${bridge_name}"
  local ovs_interface="ovs-if-${bridge_name}"
  local default_port_name="ovs-port-${port_name}" # ovs-port-phys0
  local bridge_interface_name="ovs-if-${port_name}" # ovs-if-phys0
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
  # find the MAC from OVS config or the default interface to use for OVS internal port
  # this prevents us from getting a different DHCP lease and dropping connection
  if ! iface_mac=$(<"/sys/class/net/${iface}/address"); then
    echo "Unable to determine default interface MAC"
    exit 1
  fi
  echo "MAC address found for iface: ${iface}: ${iface_mac}"
  # find MTU from original iface
  iface_mtu=$(ip link show "$iface" | awk '{print $5; exit}')
  if [[ -z "$iface_mtu" ]]; then
    echo "Unable to determine default interface MTU, defaulting to 1500"
    iface_mtu=1500
  else
    echo "MTU found for iface: ${iface}: ${iface_mtu}"
  fi
  # store old conn for later
  old_conn=$(nmcli --fields UUID,DEVICE conn show --active | awk "/\s${iface}\s*\$/ {print \$1}")
  # create bridge
  if ! nmcli connection show "$bridge_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-br "$bridge_name"
    nmcli c add type ovs-bridge \
        con-name "$bridge_name" \
        conn.interface "$bridge_name" \
        802-3-ethernet.mtu ${iface_mtu}
  fi
  # find default port to add to bridge
  if ! nmcli connection show "$default_port_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-port "$bridge_name" ${iface}
    nmcli c add type ovs-port conn.interface ${iface} master "$bridge_name" con-name "$default_port_name"
  fi
  if ! nmcli connection show "$ovs_port" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-port "$bridge_name" "$bridge_name"
    nmcli c add type ovs-port conn.interface "$bridge_name" master "$bridge_name" con-name "$ovs_port"
  fi
  extra_phys_args=()
  # check if this interface is a vlan, bond, team, or ethernet type
  if [ $(nmcli --get-values connection.type conn show ${old_conn}) == "vlan" ]; then
    iface_type=vlan
    vlan_id=$(nmcli --get-values vlan.id conn show ${old_conn})
    if [ -z "$vlan_id" ]; then
      echo "ERROR: unable to determine vlan_id for vlan connection: ${old_conn}"
      exit 1
    fi
    vlan_parent=$(nmcli --get-values vlan.parent conn show ${old_conn})
    if [ -z "$vlan_parent" ]; then
      echo "ERROR: unable to determine vlan_parent for vlan connection: ${old_conn}"
      exit 1
    fi
    extra_phys_args=( dev "${vlan_parent}" id "${vlan_id}" )
  elif [ $(nmcli --get-values connection.type conn show ${old_conn}) == "bond" ]; then
    iface_type=bond
    # check bond options
    bond_opts=$(nmcli --get-values bond.options conn show ${old_conn})
    if [ -n "$bond_opts" ]; then
      extra_phys_args+=( bond.options "${bond_opts}" )
    fi
  elif [ $(nmcli --get-values connection.type conn show ${old_conn}) == "team" ]; then
    iface_type=team
    # check team config options
    team_config_opts=$(nmcli --get-values team.config -e no conn show ${old_conn})
    if [ -n "$team_config_opts" ]; then
      # team.config is json, remove spaces to avoid problems later on
      extra_phys_args+=( team.config "${team_config_opts//[[:space:]]/}" )
    fi
  else
    iface_type=802-3-ethernet
  fi
  # use ${extra_phys_args[@]+"${extra_phys_args[@]}"} instead of ${extra_phys_args[@]} to be compatible with bash 4.2 in RHEL7.9
  if ! nmcli connection show "$bridge_interface_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists destroy interface ${iface}
    nmcli c add type ${iface_type} conn.interface ${iface} master "$default_port_name" con-name "$bridge_interface_name" \
    connection.autoconnect-priority 100 connection.autoconnect-slaves 1 802-3-ethernet.mtu ${iface_mtu} \
    ${extra_phys_args[@]+"${extra_phys_args[@]}"}
  fi
  # Get the new connection uuid
  new_conn=$(nmcli -g connection.uuid conn show "$bridge_interface_name")
  # Update connections with master property set to use the new connection
  replace_connection_master $old_conn $new_conn
  replace_connection_master $iface $new_conn
  if ! nmcli connection show "$ovs_interface" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists destroy interface "$bridge_name"
    if nmcli --fields ipv4.method,ipv6.method conn show $old_conn | grep manual; then
      echo "Static IP addressing detected on default gateway connection: ${old_conn}"
      # find and copy the old connection to get the address settings
      if egrep -l "^uuid=$old_conn" ${NM_CONN_PATH}/*; then
        old_conn_file=$(egrep -l "^uuid=$old_conn" ${NM_CONN_PATH}/*)
        cloned=false
      else
        echo "WARN: unable to find NM configuration file for conn: ${old_conn}. Attempting to clone conn"
        nmcli conn clone ${old_conn} ${old_conn}-clone
        shopt -s nullglob
        old_conn_files=(${NM_CONN_PATH}/"${old_conn}"-clone*)
        shopt -u nullglob
        if [ ${#old_conn_files[@]} -ne 1 ]; then
          echo "ERROR: unable to locate cloned conn file for ${old_conn}-clone"
          exit 1
        fi
        old_conn_file="${old_conn_files[0]}"
        cloned=true
        echo "Successfully cloned conn to ${old_conn_file}"
      fi
      echo "old connection file found at: ${old_conn_file}"
      old_basename=$(basename "${old_conn_file}" .nmconnection)
      new_conn_file="${old_conn_file/${NM_CONN_PATH}\/$old_basename/${NM_CONN_PATH}/$ovs_interface}"
      if [ -f "$new_conn_file" ]; then
        echo "WARN: existing $bridge_name interface file found: $new_conn_file, which is not loaded in NetworkManager...overwriting"
      fi
      cp -f "${old_conn_file}" ${new_conn_file}
      restorecon ${new_conn_file}
      if $cloned; then
        nmcli conn delete ${old_conn}-clone
        rm -f "${old_conn_file}"
      fi
      ovs_port_conn=$(nmcli --fields connection.uuid conn show "$ovs_port" | awk '{print $2}')
      br_iface_uuid=$(cat /proc/sys/kernel/random/uuid)
      # modify file to work with OVS and have unique settings
      sed -i '/^\[connection\]$/,/^\[/ s/^uuid=.*$/uuid='"$br_iface_uuid"'/' ${new_conn_file}
      sed -i '/^multi-connect=.*$/d' ${new_conn_file}
      sed -i '/^\[connection\]$/,/^\[/ s/^type=.*$/type=ovs-interface/' ${new_conn_file}
      sed -i '/^\[connection\]$/,/^\[/ s/^id=.*$/id='"$ovs_interface"'/' ${new_conn_file}
      sed -i '/^\[connection\]$/a slave-type=ovs-port' ${new_conn_file}
      sed -i '/^\[connection\]$/a master='"$ovs_port_conn" ${new_conn_file}
      if grep 'interface-name=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[connection\]$/,/^\[/ s/^interface-name=.*$/interface-name='"$bridge_name"'/' ${new_conn_file}
      else
        sed -i '/^\[connection\]$/a interface-name='"$bridge_name" ${new_conn_file}
      fi
      if ! grep 'cloned-mac-address=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[ethernet\]$/a cloned-mac-address='"$iface_mac" ${new_conn_file}
      else
        sed -i '/^\[ethernet\]$/,/^\[/ s/^cloned-mac-address=.*$/cloned-mac-address='"$iface_mac"'/' ${new_conn_file}
      fi
      if grep 'mtu=' ${new_conn_file} &> /dev/null; then
        sed -i '/^\[ethernet\]$/,/^\[/ s/^mtu=.*$/mtu='"$iface_mtu"'/' ${new_conn_file}
      else
        sed -i '/^\[ethernet\]$/a mtu='"$iface_mtu" ${new_conn_file}
      fi
      cat <<EOF >> ${new_conn_file}
[ovs-interface]
type=internal
EOF
      nmcli c load ${new_conn_file}
      echo "Loaded new $ovs_interface connection file: ${new_conn_file}"
    else
      extra_if_brex_args=""
      # check if interface had ipv4/ipv6 addresses assigned
      num_ipv4_addrs=$(ip -j a show dev ${iface} | jq ".[0].addr_info | map(. | select(.family == \"inet\")) | length")
      if [ "$num_ipv4_addrs" -gt 0 ]; then
        extra_if_brex_args+="ipv4.may-fail no "
      fi
      # IPV6 should have at least a link local address. Check for more than 1 to see if there is an
      # assigned address.
      num_ip6_addrs=$(ip -j a show dev ${iface} | jq ".[0].addr_info | map(. | select(.family == \"inet6\" and .scope != \"link\")) | length")
      if [ "$num_ip6_addrs" -gt 0 ]; then
        extra_if_brex_args+="ipv6.may-fail no "
      fi
      # check for dhcp client ids
      dhcp_client_id=$(nmcli --get-values ipv4.dhcp-client-id conn show ${old_conn})
      if [ -n "$dhcp_client_id" ]; then
        extra_if_brex_args+="ipv4.dhcp-client-id ${dhcp_client_id} "
      fi
      dhcp6_client_id=$(nmcli --get-values ipv6.dhcp-duid conn show ${old_conn})
      if [ -n "$dhcp6_client_id" ]; then
        extra_if_brex_args+="ipv6.dhcp-duid ${dhcp6_client_id} "
      fi
      ipv6_addr_gen_mode=$(nmcli --get-values ipv6.addr-gen-mode conn show ${old_conn})
      if [ -n "$ipv6_addr_gen_mode" ]; then
        extra_if_brex_args+="ipv6.addr-gen-mode ${ipv6_addr_gen_mode} "
      fi
      nmcli c add type ovs-interface slave-type ovs-port conn.interface "$bridge_name" master "$ovs_port" con-name \
        "$ovs_interface" 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac} \
        ipv4.route-metric "${bridge_metric}" ipv6.route-metric "${bridge_metric}" ${extra_if_brex_args}
    fi
  fi
  configure_driver_options "${iface}"
  update_nm_conn_files "$bridge_name" "$port_name"
}
# Used to remove a bridge
remove_ovn_bridges() {
  bridge_name=${1}
  port_name=${2}
  # Reload configuration, after reload the preferred connection profile
  # should be auto-activated
  update_nm_conn_files ${bridge_name} ${port_name}
  rm_nm_conn_files
  # NetworkManager will not remove ${bridge_name} if it has the patch port created by ovn-kubernetes
  # so remove explicitly
  ovs-vsctl --timeout=30 --if-exists del-br ${bridge_name}
}
# Removes any previous ovs configuration
remove_all_ovn_bridges() {
  echo "Reverting any previous OVS configuration"
  
  remove_ovn_bridges br-ex phys0
  if [ -d "/sys/class/net/br-ex1" ]; then
    remove_ovn_bridges br-ex1 phys1
  fi
  
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
  
  # Reload NM if necessary
  reload_nm
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
    # check ipv4
    # never use the interface that's specified in extra_bridge_file
    # never use br-ex1
    if [ "${extra_bridge}" != "" ]; then
      iface=$(ip route show default | grep -v "br-ex1" | grep -v "${extra_bridge}" | awk '{ if ($4 == "dev") { print $5; exit } }')
    else
      iface=$(ip route show default | grep -v "br-ex1" | awk '{ if ($4 == "dev") { print $5; exit } }')
    fi
    if [[ -n "${iface}" ]]; then
      break
    fi
    # check ipv6
    # never use the interface that's specified in extra_bridge_file
    # never use br-ex1
    if [ "${extra_bridge}" != "" ]; then
      iface=$(ip -6 route show default | grep -v "br-ex1" | grep -v "${extra_bridge}" | awk '{ if ($4 == "dev") { print $5; exit } }')
    else
      iface=$(ip -6 route show default | grep -v "br-ex1" | awk '{ if ($4 == "dev") { print $5; exit } }')
    fi
    if [[ -n "${iface}" ]]; then
      break
    fi
    counter=$((counter+1))
    sleep 5
  done
  # if the default interface does not point out of br-ex or br-ex1
  if [ "${iface}" != "br-ex" ] && [ "${iface}" != "br-ex1" ]; then
    # determine if an interface default hint exists from a previous run
    # and if the interface has a valid default route
    iface_default_hint=$(get_iface_default_hint "${iface_default_hint_file}")
    if [ "${iface_default_hint}" != "" ] &&
       [ "${iface_default_hint}" != "${iface}" ]; then
      # start wherever count left off in the previous loop
      # allow this for one more iteration than the previous loop
      while [ ${counter} -le 12 ]; do
        # check ipv4
        if [ "$(ip route show default dev "${iface_default_hint}")" != "" ]; then
          iface="${iface_default_hint}"
          break
        fi
        # check ipv6
        if [ "$(ip -6 route show default dev "${iface_default_hint}")" != "" ]; then
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
  nmcli -g all device | grep -v unmanaged
  nmcli -g all connection
  ip -d address show
  ip route show
  ip -6 route show
}
# Setup an exit trap to rollback on error
handle_exit() {
  e=$?
  [ $e -eq 0 ] && print_state && exit 0
  echo "ERROR: configure-ovs exited with error: $e"
  print_state
  # copy configuration to tmp
  dir=$(mktemp -d -t "configure-ovs-$(date +%Y-%m-%d-%H-%M-%S)-XXXXXXXXXX")
  update_nm_conn_files br-ex phys0
  copy_nm_conn_files "$dir"
  update_nm_conn_files br-ex1 phys1
  copy_nm_conn_files "$dir"
  echo "Copied OVS configuration to $dir for troubleshooting"
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
if ! rpm -qa | grep -q openvswitch; then
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
  convert_to_bridge "$iface" "br-ex" "phys0" "${BRIDGE_METRIC}"
  # Check if we need to configure the second bridge
  if [ -f "$extra_bridge_file" ] && (! nmcli connection show br-ex1 &> /dev/null || ! nmcli connection show ovs-if-phys1 &> /dev/null); then
    interface=$(head -n 1 $extra_bridge_file)
    convert_to_bridge "$interface" "br-ex1" "phys1" "${BRIDGE1_METRIC}"
  fi
  # Check if we need to remove the second bridge
  if [ ! -f "$extra_bridge_file" ] && (nmcli connection show br-ex1 &> /dev/null || nmcli connection show ovs-if-phys1 &> /dev/null); then
    update_nm_conn_files br-ex1 phys1
    rm_nm_conn_files
  fi
  # Remove bridges created by openshift-sdn
  ovs-vsctl --timeout=30 --if-exists del-br br0
  # Recycle NM connections
  reload_nm
  # Make sure everything is activated
  activate_nm_conn ovs-if-phys0
  activate_nm_conn ovs-if-br-ex
  if [ -f "$extra_bridge_file" ]; then
    activate_nm_conn ovs-if-phys1
    activate_nm_conn ovs-if-br-ex1
  fi
elif [ "$1" == "OpenShiftSDN" ]; then
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  rollback_nm
  
  # Remove bridges created by ovn-kubernetes
  ovs-vsctl --timeout=30 --if-exists del-br br-int -- --if-exists del-br br-local
fi
