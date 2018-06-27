#!/bin/bash -xe
echo "shell-scripts/global_setup.sh"
#
# Executes all the commands that must be run on any job
#
shopt -s nullglob

main() {
    local failed=false

    setup_os_repos
    mk_wokspace_dirs
    remove_packages || failed=true
    extra_packages || failed=true
    user_configuration || failed=true
    nested_kvm || failed=true
    verify_ipv6 || failed=true
    load_ovs_module || failed=true
    if can_sudo systemctl; then
        start_services || failed=true
        setup_postfix || failed=true
        disable_dnf_makecache || failed=true
        docker_setup || failed=true
    else
        log WARN "Skipping services setup - not enough sudo permissions"
    fi
    lago_setup || failed=true
    ensure_user_ssh_dir_permissions || failed=true

    # If we failed in any step, abort to avoid breaking the host
    if $failed; then
        log ERROR "Aborting."
        return 1
    fi
    return 0
}

remove_packages() {
    # Remove packages if they are installed
    local package_list=(python2-paramiko)
    local tool

    if [[ -e '/usr/bin/dnf' ]]; then
        # Fedora-specific packages
        package_list+=()
        if can_sudo dnf; then
            tool='dnf'
        fi
    else
        # CentOS-specific packages
        package_list+=()
        if can_sudo yum; then
            tool='yum'
        fi
    fi
    if [[ -z "$tool" ]]; then
        log WARN "Skipping removal of packages. No permissions."
        return
    fi
    local failed=0
    for package in "${package_list[@]}"; do
        if ! "$tool" list --disablerepo='*' "$package"; then
            log INFO "Skipping $package: not installed"
            continue
        fi
        log INFO "Removing $package"
        if ! sudo -n "$tool" remove -y "$package"; then
            log WARN "Could not remove $package"
            failed=1
        fi
    done
    return $failed
}

setup_os_repos() {
    local os
    local arch
    local conf_file

    if ! can_sudo cp; then
        log WARN "Skipping slave repo setup - no sudo permissions"
    fi
    if [[ ! -e /etc/os-release ]]; then
        log INFO "Cannot find '/etc/os-release', Skipping slave repo config".
        return
    fi
    source /etc/os-release
    os="${ID:?}${VERSION_ID:?}"
    arch="$(uname -i)"
    log DEBUG "Detected slave OS: $os"
    log DEBUG "Detected slave arch: $arch"
    if [[ $arch == x86_64 ]]; then
        conf_file="$WORKSPACE/jenkins/data/slave-repos/${os}.conf"
    else
        conf_file="$WORKSPACE/jenkins/data/slave-repos/${os}-${arch}.conf"
    fi
    if [[ ! -e "$conf_file" ]]; then
        log INFO "File: '$conf_file' not found. Skipping slave OS repo config".
        return
    fi
    log INFO "Configuring slave repos with: '$conf_file'"
    for yum_conf in /etc{{/yum,}/yum.conf,/dnf/dnf.conf}; do
        [[ -f "$yum_conf" ]] || continue
        if cmp --quiet "$yum_conf" "$conf_file"; then
            log INFO: "'$yum_conf' does not need to be updated"
            continue
        fi
        log INFO: "Placing repo configuration in: '$yum_conf'"
        sudo -n cp --backup --suffix=.rbk "$conf_file" "$yum_conf"
        sudo -n restorecon "$yum_conf"
    done
}

mk_wokspace_dirs() {
    rm -rf "$WORKSPACE/tmp"
    mkdir -p "$WORKSPACE/"{tmp,exported-artifacts}
}

lago_setup() {
    # Allow qemu to acces VM images located at $WORKSPACE
    local configure_qemu=true

    for cmd in "usermod" "chmod"; do
        can_sudo "$cmd" && continue
        configure_qemu=false
        log WARN "Can't configure qemu user, no sudo access to $cmd"
    done

    "$configure_qemu" && {
        sudo -n usermod -a -G "$USER" qemu || {
            log ERROR "Failed to add user qemu to group $USER"
            return 1
        }
        verify_set_permissions 750 "$HOME" || {
            log ERROR "Failed to set permissions on $HOME"
            #Rollback
            gpasswd -d qemu "$USER"
            return 1
        }
    }

    # create directory for lago cache and repos
    if [ ! -d /var/lib/lago ]; then
        if can_sudo install; then
            log INFO "Creating lago directory"
            sudo -n install -m 0644 -d /var/lib/lago || log WARN "unable to create lago directory"
        else
            log WARN "Lago directory missing. This may cause issues. Unable to fix, ignoring."
        fi
    fi
    # open up port 8585 for lago if needed
    local fw_service_name="ovirtlago"
    if can_sudo firewall-cmd; then
        #check if the service is defined in firewalld
        if [[ ! "$(sudo -n firewall-cmd --query-service="$fw_service_name")" ]]; then
            local failed=false
            log INFO "Defining firewalld service for $fw_service_name"
            sudo -n firewall-cmd --permanent --new-service="$fw_service_name" && \
            sudo -n firewall-cmd --permanent --service="$fw_service_name" \
                --add-port=8585/tcp && \
            sudo -n firewall-cmd --permanent --service="$fw_service_name" \
                --set-destination=ipv4:192.168.0.0/16 && \
            sudo -n firewall-cmd --permanent --add-service="$fw_service_name" && \
            sudo -n firewall-cmd --reload || failed=true
            if $failed; then
                log ERROR "firewalld service definition finished with errors, aborting"
                # roll back in case of setup failure by trying to delete service definition
                sudo -n firewall-cmd --permanent --remove-service="$fw_service_name" || failed=true
                sudo -n firewall-cmd --remove-service="$fw_service_name" || failed=true
                return 1
            fi
        fi
    fi
}

user_configuration() {
    local failed=0
    # ensure user is member of mock group
    if [[ "$EUID" -ne 0 ]]; then
        if ! groups | grep -q '\bmock\b'; then
            log ERROR "$USER user is not part of the mock group"
            if can_sudo usermod; then
                if sudo -n usermod -a -G mock $USER; then
                    log INFO "mock group membership added, agent restart required"
                else
                    log ERROR "Failed to set mock group membership"
                fi
            else
                log ERROR "No sudo access, please add user to mock group manually!"
            fi
            (( ++failed ))
        fi
    fi
    # ensure the number of open files in the kernel is OK
    if [[ "$(/sbin/sysctl -n fs.file-max)" -lt "64000" ]]; then
        if can_sudo /sbin/sysctl; then
            log INFO "Increasing kernel open file limit"
            if ! sudo -n /sbin/sysctl fs.file-max=64000; then
                log ERROR "Failed to increase kernel open file limit"
                (( ++failed ))
            fi
        else
            log WARN "Kernel open file limit low. This may cause issues. Unable to fix, ignoring."
        fi
    fi
    # ensure ulimint on open files for the user is OK
    if [[ "$(ulimit -Sn)" -lt "64000" ]]; then
        if can_sudo tee; then
            if \
                printf "* soft nofile 64000\n* hard nofile 96000\n" | \
                sudo -n tee /etc/security/limits.d/10-nofile.conf
            then
                log INFO "Increased user open file limit. Agent restart required"
            else
                log ERROR "Failed to set user open file limit"
                (( ++failed ))
            fi
        else
            log WARN "User open file limit low. This may cause issues. Unable to fix, ignoring."
        fi
    fi
    return $failed
}

is_nested_kvm_enabled() {
    #check if nested KVM on Intel is enabled
    local i_nested_path="/sys/module/kvm_intel/parameters/nested"
    [[ -f "$i_nested_path" ]] || return 1
    [[ "$(cat $i_nested_path)" != "N" ]] || return 1
    return 0
}

nested_kvm() {
    # Writing to local container file has no effect so this whole function is
    # useless in a cotnainer.
    [[ -n "$STDCI_SLAVE_CONTAINER_NAME" ]] && return 0
    #enable nested KVM on Intel if missing
    #check if our hardware has Intel VT, skip otherwise
    if [[ "$(cat /proc/cpuinfo | grep vmx)" ]]; then
        #check if nested is already enabled
        if ! is_nested_kvm_enabled; then
            #check if sudo is available
            if can_sudo rmmod modprobe tee; then
                log INFO "Enabling nested KVM"
                echo "options kvm_intel nested=y" | \
                sudo -n tee /etc/modprobe.d/nested.conf
                sudo -n rmmod kvm_intel
                sudo -n modprobe kvm_intel nested=y
                #check if the change went fine and nested is enabled
                if is_nested_kvm_enabled; then return 0
                else
                    log ERROR "failed to enable nested KVM, aborting"
                    return 1
                fi
            else
                log WARN "Nested KVM missing. This may cause issues. Unable to fix, ignoring."
                return 0
            fi
        fi
    fi
}

verify_ipv6() {
    # check if any routes received via router advertisements are in place
    if [[ "$(/sbin/ip -6 route list proto ra)" ]]; then
        # create a list of interfaces with such routes to check accept_ra value
        local iflist="$(/sbin/ip -6 route list proto ra | grep -oP '(?<=dev )(\w+)' | sort | uniq)"
        for ifname in $iflist; do
            local ra_conf_path="/proc/sys/net/ipv6/conf/$ifname/accept_ra"
            if [[ -f "$ra_conf_path" ]]; then
                if [[ "$(cat $ra_conf_path)" -ne "2" ]]; then
                    if can_sudo /sbin/sysctl; then
                        echo "setting accept_ra=2 on $ifname"
                        sudo -n /sbin/sysctl net.ipv6.conf.$ifname.accept_ra=2
                        if [[ "$(cat $ra_conf_path)" -ne "2" ]]; then
                            log ERROR "Falied to configure accept_ra to 2 on $ifname"
                            return 1
                        fi
                    else
                        log WARN "RA routes detected on $ifname but accept_ra!=2"
                        log WARN "this may cause libvirt issues. Unable to fix, ignoring."
                    fi
                fi
            fi
        done
    fi
    return 0
}

extra_packages() {
    # Add extra packages we need for STDCI
    # packages common for all distros
    local package_list=(
        git mock sed bash procps-ng createrepo python-paramiko
        PyYAML python2-pyxdg python-jinja2 python-py python-six
    )
    if [[ -e '/usr/bin/dnf' ]]; then
        # Fedora-specific packages
        package_list+=(python3-PyYAML python3-py python3-pyxdg)
        if can_sudo dnf; then
            package_list+=(
                firewalld haveged libvirt qemu-kvm python3-six
                nosync libselinux-utils kmod
            )
        fi
    else
        # CentOS-specific packages
        package_list+=(python34-PyYAML)
        if can_sudo yum; then
            package_list+=(
                firewalld haveged libvirt qemu-kvm-rhev
                nosync libselinux-utils kmod
            )
        fi
    fi
    verify_packages "${package_list[@]}"
}

docker_setup () {
    #Install docker engine and start the service
    log INFO "Trying to setup Docker"
    verify_packages docker || return 1
    log INFO "Trying to setup Docker python API"
    if ! verify_packages python2-docker python3-docker; then
        # We failed to install the new API version, try to install the old one
        log WARN "Failed to install new docker API (that is ok)."
        log INFO "Trying to install old docker API"
        if ! verify_packages python-docker-py; then
            log ERROR "Failed to install docker API."
            return 1
        fi
    fi
    log INFO "Starting docker service"
    if ! sudo -n systemctl start docker; then
        log ERROR "Failed to start docker service"
        return 1
    fi
    if ! docker_ensure_iptables_chain; then
        return 1
    fi
    return 0
}

docker_ensure_iptables_chain() {
    log INFO "Ensuring that the Docker iptables chain is configured"
    if sudo iptables -L DOCKER > /dev/null; then
        return 0
    fi
    log INFO "Restarting Docker to restore iptables chain"
    if ! sudo -n systemctl restart docker; then
        log ERROR "Failed to restart docker service"
        return 1
    fi
    if sudo -n iptables -L DOCKER > /dev/null; then
        log INFO "Docker iptables chain restored successfully"
        return 0
    fi
    log ERROR "Docker iptables chain still missing"
    return 1
}

setup_postfix() {
    verify_packages postfix
    sudo -n systemctl enable postfix
    sudo -n systemctl start postfix
}

start_services() {
    #start important services
    sudo -n systemctl start libvirtd haveged firewalld
}

verify_packages() {
    local packages=("$@")

    local tool='/usr/bin/dnf'
    local tool_inst_opts=(--best --allowerasing)
    if [[ ! -e "$tool" ]]; then
        tool=/bin/yum
        tool_inst_opts=()

    fi
    if can_sudo "$tool"; then
        sudo -n "$tool" "${tool_inst_opts[@]}" install -y "${packages[@]}"
    fi
    local failed=0
    for package in "${packages[@]}"; do
        rpm -q --quiet --whatprovides "$package" && continue
        log ERROR "package '$package' is not, and could not be, installed"
        (( ++failed ))
    done
    return $failed
}

ensure_user_ssh_dir_permissions() {
    local failed=0


    if [[ -e "$HOME/.ssh" ]]; then
        verify_set_ownership "$HOME/.ssh" || failed=1
        verify_set_permissions 700 "$HOME/.ssh" || failed=1
    fi
    if [[ -f "$HOME/.ssh/known_hosts" ]]; then
        verify_set_ownership "$HOME/.ssh/known_hosts" || failed=1
        verify_set_permissions 644 "$HOME/.ssh/known_hosts" || failed=1
    fi
    return $failed
}

disable_dnf_makecache() {
    # disable dnf-makecache on Fedora systems
    # as it interferes with running jobs by locking dnf
    if [ -f "/etc/systemd/system/basic.target.wants/dnf-makecache.timer" ]; then
        log INFO "disabling dnf-makecache";
        sudo -n systemctl disable dnf-makecache.timer
        sudo -n systemctl stop dnf-makecache.service
        sudo -n systemctl disable dnf-makecache.service
        # check if the symlink still exists and failing if so
        if [ -f "/etc/systemd/system/basic.target.wants/dnf-makecache.timer" ]; then
            log ERROR "failed to disable dnf-makecache"
            return 1
        fi
    fi
}

is_ovs_module_loaded() {
    # check if openvswitch kernel module is loaded
    /usr/sbin/lsmod | cut -d" " -f1 | grep openvswitch > /dev/null || return 1
    return 0
}

load_ovs_module() {
    # load OVS module to ensure VDSM tests are run properly
    if can_sudo /usr/sbin/modprobe; then
        if ! is_ovs_module_loaded; then
            log INFO "loading OVS module"
            sudo -n /usr/sbin/modprobe openvswitch
            if is_ovs_module_loaded; then return 0
            else
                log ERROR "failed to load OVS module, aborting"
                return 1
            fi
        fi
    fi
}

verify_set_ownership() {
    local path_to_set="${1:?Error. path must be provided}"
    local owner="${2:-"$(id -un)"}"
    local group="${3:-"$(id -gn)"}"

    if [[ ! -O "$path_to_set" || ! -G "$path_to_set" ]]; then
        log WARN "$path_to_set is not owned by ${owner}:${group}. Will try to fix"
        if ! can_sudo chown; then
            log ERROR "No permissions to fix."
            return 1
        fi
        sudo -n chown "$owner":"$group" "$path_to_set" || return 1
    fi
}

verify_set_permissions() {
    local target_permissions="${1:?Error. file permissions must be provided (OCTAL)}"
    local path_to_set="${2:?Error. path must be provided}"

    local access="$(stat -c %a "$path_to_set")"
    if [[ "$access" != "$target_permissions" ]]; then
        if ! can_sudo chmod; then
            log ERROR "Wrong access right to $path_to_set - no permissions to fix."
            log ERROR "Access rights to $path_to_set: $access"
            return 1
        fi
        sudo -n chmod "$target_permissions" "$path_to_set" || return 1
    fi

    return 0
}

can_sudo() {
    local cmd

    for cmd in "$@"; do
        sudo -nl $cmd >& /dev/null || return 1
    done
}

log() {
    local level="${1:?}"
    shift
    local message="$*"
    local prefix

    if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
        prefix="global_setup[${FUNCNAME[1]}]"
    else
        prefix="global_setup"
    fi
    echo "$prefix $level: $message"
}

main "@$"
