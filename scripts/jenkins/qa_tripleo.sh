#!/bin/bash

set -eux

zypper="zypper --non-interactive"

function setup_package_repositories()
{
    # setup repos
    local VERSION=11
    local REPO=SLE_11_SP3
    if grep "^VERSION = 1[2-4]\\.[0-5]" /etc/SuSE-release ; then
        VERSION=$(awk -e '/^VERSION = 1[2-4]\./{print $3}' /etc/SuSE-release)
        REPO=openSUSE_$VERSION
    fi

    zypper rr cloudhead || :

    $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/$REPO/ cloud || :
    # no staging for master
    $zypper mr --priority 22 cloud

    $zypper -n --gpg-auto-import-keys ref
}

function install_packages()
{
    $zypper in make patch python-PyYAML git-core busybox
    $zypper in python-os-apply-config
    $zypper in diskimage-builder tripleo-image-elements tripleo-heat-templates
    $zypper in kvm libvirt-daemon-driver-network libvirt

    # workaround kvm packaging bug
    udevadm control --reload-rules  || :
    udevadm trigger || :
    # worarkound libvirt packaging bug
    systemctl start libvirtd
    usermod -a -G libvirt root
    sleep 2
}


setup_package_repositories
install_packages


## setup some useful defaults
export NODE_ARCH=amd64
export TE_DATAFILE=/opt/stack/new/testenv.json

# temporary hacks delete me
export NODE_DIST="opensuse"

use_package=1

if [ "$use_package" = "1" ]; then
    export DIB_REPOTYPE_python_ceilometerclient=package
    export DIB_REPOTYPE_python_cinderclient=package
    export DIB_REPOTYPE_python_glanceclient=package
    export DIB_REPOTYPE_python_heatclient=package
    export DIB_REPOTYPE_python_ironicclient=package
    export DIB_REPOTYPE_python_keystoneclient=package
    export DIB_REPOTYPE_python_neutronclient=package
    export DIB_REPOTYPE_python_novaclient=package
    export DIB_REPOTYPE_python_swiftclient=package

    export DIB_REPOTYPE_ceilometer=package
    export DIB_REPOTYPE_glance=package
    export DIB_REPOTYPE_heat=package
    export DIB_REPOTYPE_keystone=package
    export DIB_REPOTYPE_neutron=package
    export DIB_REPOTYPE_nova=package
    export DIB_REPOTYPE_nova_baremetal=package
    export DIB_REPOTYPE_swift=package
fi

export DIB_COMMON_ELEMENTS=${DIB_COMMON_ELEMENTS:-"stackuser"}
export LIBVIRT_NIC_DRIVER=virtio



virsh net-define /usr/share/libvirt/networks/default.xml || :

mkdir -p /opt/stack/new/

if [ ! -d /opt/stack/new/tripleo-incubator ]; then
    (
        cd /opt/stack/new/
        git clone git://git.openstack.org/openstack/tripleo-incubator
    )
fi


if [ ! -f /opt/stack/new/testenv.json ]; then

    # This should be part of the devtest scripts imho, but
    # currently isn't.
    (
        export PATH=$PATH:/opt/stack/new/tripleo-incubator/scripts/

        install-dependencies

        cleanup-env

        setup-network

        setup-seed-vm -a $NODE_ARCH

        create-nodes 1 2048 20 amd64 4 brbm
    )

    NODEMACS=
    for node in $(virsh list --all --name | grep brbm); do
        NODEMACS="$(virsh dumpxml $node | grep 'mac address' | awk -F \' 'NR==1,/mac address/ {print $2}')${NODEMACS:+ }$NODEMACS"
    done

    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -f ~/.ssh/id_rsa -P ''
    fi
    cat - > /opt/stack/new/testenv.json <<EOF
    {
        "host-ip": "192.168.122.1",
        "seed-ip": "192.0.2.1",
        "seed-route-dev": "virbr0",
        "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
        "node-macs": "$NODEMACS",
        "ssh-user": "root",
        "env-num": "2",
        "arch": "amd64",
        "node-cpu": "1",
        "node-mem": "2048",
        "node-disk": "20",
        "ssh-key": "$(python -c 'print open("/root/.ssh/id_rsa").read().replace("\n", "\\n")')"
    }
EOF
fi

# When launched interactively, break on error

if [ -t 0 ]; then
    export break=after-error
fi

# Use tripleo-ci from git

if [ ! -d tripleo-ci ]; then
    git clone git://git.openstack.org/openstack-infra/tripleo-ci
fi

# Use diskimage-builder from packages

if [ ! -d /opt/stack/new/diskimage-builder ]; then
    mkdir -p /opt/stack/new/diskimage-builder
    ln -s /usr/bin /opt/stack/new/diskimage-builder/bin
    ln -s /usr/share/diskimage-builder/elements /opt/stack/new/diskimage-builder/elements
    ln -s /usr/share/diskimage-builder/lib /opt/stack/new/diskimage-builder/lib
fi

# Use tripleo-image-elements from packages

if [ ! -d /opt/stack/new/tripleo-image-elements ]; then
    mkdir -p /opt/stack/new/tripleo-image-elements
    ln -s /usr/bin /opt/stack/new/tripleo-image-elements/bin
    ln -s /usr/share/tripleo-image-elements /opt/stack/new/tripleo-image-elements/elements
fi

# Use tripleo-heat-templates from packages

if [ ! -d /opt/stack/new/tripleo-heat-templates ]; then
    git clone git://git.openstack.org/openstack/tripleo-heat-templates /opt/stack/new/tripleo-heat-templates
fi

cd tripleo-ci

export USE_CACHE=1
export TRIPLEO_CLEANUP=0

exec ./toci_devtest.sh
