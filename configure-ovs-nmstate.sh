#!/bin/bash
set -eux

get_iface_attr() {
  local iface=$1
  local attr=$2
  nmstatectl show $iface --json |jq -r --arg attr $attr '.interfaces[0][$attr]'
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
    echo "Networking already configured and up for ${bridge-name}!"
    return
  fi
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
# Removes all configuration and reloads NM if necessary
rollback_nm() {
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  remove_all_ovn_bridges
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
  local extra_bridge_file="$1"
  local extra_bridge=""
  if [ -f "${extra_bridge_file}" ]; then
    extra_bridge=$(cat ${extra_bridge_file})
  fi
  # find default interface
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
  ovnk_config_dir='/etc/ovnk'
  extra_bridge_file="${ovnk_config_dir}/extra_bridge"
  # make sure to create ovnk_config_dir if it does not exist, yet
  mkdir -p "${ovnk_config_dir}"
  # make sure to create ovnk_var_dir if it does not exist, yet
  mkdir -p "${ovnk_var_dir}"
  # on every boot we rollback and generate the configuration again, to take
  # in any changes that have possibly been applied in the standard
  # configuration sources
  if [ ! -f /run/configure-ovs-boot-done ]; then
    echo "Running on boot, restoring previous configuration before proceeding..."
    rollback_nm
    print_state
  fi
  touch /run/configure-ovs-boot-done
  iface=$(get_default_interface "$extra_bridge_file")
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
