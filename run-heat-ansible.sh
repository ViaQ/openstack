#!/bin/sh

set -ex

if [ -n "$OPENRC" ] ; then
    . $OPENRC
fi

PROPERTIES_FILE=${PROPERTIES_FILE:-${1:-properties-origin14.yaml}}
STACK_NAME=`awk '$1 == "run_stack_name:" {print $2}' $PROPERTIES_FILE`
STACK_NAME=${STACK_NAME:-origin-14.$USER.test}
STACK_FILE=`awk '$1 == "run_stack_file:" {print $2}' $PROPERTIES_FILE`
STACK_FILE=${STACK_FILE:-heat-origin-1.x.yaml}
SERVER_NAME=`awk '$1 == "oshift_hostname:" {print $2}' $PROPERTIES_FILE`
SERVER_NAME=${SERVER_NAME:-origin-14.$USER.test}
OSHIFT_ANSIBLE_DIR=${OSHIFT_ANSIBLE_DIR:-$HOME/openshift-ansible}
INSECURE_REGISTRIES=`sed -n -e '/insecure_registries:/ { s/^[ ]*insecure_registries:[ ]*//; p}' $PROPERTIES_FILE`
PACKAGE_REPO=`awk '$1 == "package_repo:" {print $2}' $PROPERTIES_FILE`
VARIANT=`awk '$1 == "variant:" {print $2}' $PROPERTIES_FILE`
VARIANT=${VARIANT:-origin}
VARIANT_VERSION=`awk '$1 == "variant_version:" {print $2}' $PROPERTIES_FILE`
VARIANT_VERSION=${VARIANT_VERSION:-1.4}
OPENSHIFT_VERSION=`awk '$1 == "openshift_version:" {print $2}' $PROPERTIES_FILE`
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-1.4.0}
LOGGING_IMAGE_VERSION=`awk '$1 == "logging_image_version:" {print $2}' $PROPERTIES_FILE`
LOGGING_IMAGE_VERSION=${LOGGING_IMAGE_VERSION:-latest}
LOGGING_IMAGE_PREFIX=`awk '$1 == "logging_image_prefix:" {print $2}' $PROPERTIES_FILE`
LOGGING_IMAGE_PREFIX=${LOGGING_IMAGE_PREFIX:-"docker.io/openshift/origin-"}
KIBANA_HOSTNAME=`awk '$1 == "kibana_hostname:" {print $2}' $PROPERTIES_FILE`
KIBANA_HOSTNAME=${KIBANA_HOSTNAME:-$SERVER_NAME}
KIBANA_OPS_HOSTNAME=`awk '$1 == "kibana_ops_hostname:" {print $2}' $PROPERTIES_FILE`
KIBANA_OPS_HOSTNAME=${KIBANA_OPS_HOSTNAME:-kibana-14-ops.$USER.test}
ES_HOSTNAME=`awk '$1 == "es_hostname:" {print $2}' $PROPERTIES_FILE`
ES_HOSTNAME=${ES_HOSTNAME:-es.$SERVER_NAME}
ES_OPS_HOSTNAME=`awk '$1 == "es_ops_hostname:" {print $2}' $PROPERTIES_FILE`
ES_OPS_HOSTNAME=${ES_OPS_HOSTNAME:-es-ops.$SERVER_NAME}

if [ -z "$START_STEP" ] ; then
    echo Error: must define START_STEP
    exit 1
fi

wait_until_cmd() {
    ii=$3
    interval=${4:-10}
    while [ $ii -gt 0 ] ; do
        $1 $2 && break
        sleep $interval
        ii=`expr $ii - $interval`
    done
    if [ $ii -le 0 ] ; then
        return 1
    fi
    return 0
}

get_machine() {
    nova list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

get_stack() {
    heat stack-list | awk -v pat=$1 '$0 ~ pat {print $2}'
}

cleanup_old_machine_and_stack() {
    stack=`get_stack $STACK_NAME`
    if [ -n "$stack" ] ; then
        heat stack-delete $stack
    fi

    if [ -n "$stack" ] ; then
        wait_s_d() {
            status=`heat stack-list | awk -v ss=$1 '$0 ~ ss {print $6}'`
            if [ "$status" = "DELETE_FAILED" ] ; then
                # try again
                heat stack-delete $1
                return 1
            fi
            test -z "`get_stack $1`"
        }
        wait_until_cmd wait_s_d $STACK_NAME 400 20
    fi

    mach=`get_machine $SERVER_NAME`
    if [ -n "$mach" ] ; then
        nova delete $mach
    fi

    if [ -n "$mach" ] ; then
        wait_n_d() { nova show $1 > /dev/null ; }
        wait_until_cmd wait_n_d $mach 400 20
    fi
}

get_float() {
    ip=`heat output-show $1 instance_ip --format shell`
    if [ -n "$ip" ] ; then
        echo $ip
        return 0
    fi
    return 1
}

get_mach_status() {
    nova console-log $SERVER_NAME
}

create_stack_and_mach_get_float_ip() {
    heat stack-create -e $PROPERTIES_FILE -f $STACK_FILE $STACK_NAME

    sleep 5
    stack=`get_stack $STACK_NAME`
    wait_until_cmd get_float $stack 400
}

get_remote_fqdn() {
    fqdn=`ssh $sshopts centos@$1 "hostname -f 2> /dev/null" 2> /dev/null`
    if echo "$fqdn" | grep -q '[.]' ; then
        echo $fqdn
        return 0
    fi
    return 1
}

get_remote_fqdn_mach_status() {
    if get_remote_fqdn $1 ; then
        return 0
    fi
    get_mach_status || :
    return 1
}

sshopts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
get_remote_fqdn_fix_hosts() {
    # get the remote fqdn - $1 is floating ip
    wait_until_cmd get_remote_fqdn_mach_status $1 500 20
    fqdn=`get_remote_fqdn $1`
    # make sure `hostname -f` resolves to the external IP on both the local and remote machine
    sudo sed -i -e "/$SERVER_NAME/d" -e "/$fqdn/d" \
         -e "/$KIBANA_HOSTNAME/d" -e "/$KIBANA_OPS_HOSTNAME/d" \
         -e "/$ES_HOSTNAME/d" -e "/$ES_OPS_HOSTNAME/d" \
         /etc/hosts
    sudo sed -i -e '$ a\
'"$1 $fqdn $SERVER_NAME $KIBANA_HOSTNAME $KIBANA_OPS_HOSTNAME $ES_HOSTNAME $ES_OPS_HOSTNAME
" /etc/hosts
    ssh $sshopts centos@$1 "echo $1 \`hostname -f\` \`hostname -s\` $SERVER_NAME $KIBANA_HOSTNAME $KIBANA_OPS_HOSTNAME $ES_HOSTNAME $ES_OPS_HOSTNAME | sudo tee -a /etc/hosts"
    sed -i -e "/$fqdn/d" -e "/$KIBANA_HOSTNAME/d" -e "/$KIBANA_OPS_HOSTNAME/d" \
        -e "/$ES_HOSTNAME/d" -e "/$ES_OPS_HOSTNAME/d" \
        ~/.ssh/known_hosts
}

if [ "$START_STEP" = clean ] ; then
    cleanup_old_machine_and_stack
    START_STEP=create
fi

ip=
stack=
if [ "$START_STEP" = create ] ; then
    create_stack_and_mach_get_float_ip
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    ip=`get_float $stack`
    START_STEP=fqdn
fi

fqdn=
if [ "$START_STEP" = fqdn ] ; then
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    get_remote_fqdn_fix_hosts $ip
    START_STEP=create-inventory
fi

get_remote_public_fqdn() {
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    # assume first entry is fqdn
    getent hosts $ip |awk '{print $2}'
}

get_remote_private_ip() {
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    ssh $sshopts centos@$ip "/usr/sbin/ip a" | awk -F'[ /]+' '/192.168/ {print $3}'
}

get_remote_private_fqdn() {
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    if [ -z "$priv_ip" ] ; then
        priv_ip=`get_remote_private_ip`
    fi
    ssh $sshopts centos@$ip "getent hosts $priv_ip" | awk '{print $2}'
}

ooconfig=$HOME/.config/openshift/installer-${VARIANT_VERSION}.cfg.yml
inventory=$HOME/.config/openshift/hosts-${VARIANT_VERSION}
if [ -n "${INSECURE_REGISTRIES:-}" ] ; then
    insecure_bool=True
else
    insecure_bool=False
fi

create_ooconfig() {
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    if [ -z "$fqdn" ] ; then
        fqdn=`get_remote_public_fqdn`
    fi
    if [ -z "$priv_ip" ] ; then
        priv_ip=`get_remote_private_ip`
    fi
    if [ -z "$priv_fqdn" ] ; then
        priv_fqdn=`get_remote_private_fqdn`
    fi
    cat <<EOF
ansible_inventory_path: $inventory
ansible_log_path: /tmp/ansible.log
ansible_ssh_user: centos
deployment:
  hosts:
  - connect_to: $fqdn
    hostname: $priv_fqdn
    ip: $priv_ip
    roles:
    - master
    - node
    public_hostname: $fqdn
    public_ip: $ip
    storage: true
    node_labels: {'region': 'infra'}
  roles:
    master:
    node:
  osm_use_cockpit: False
  openshift_hosted_logging_enable_ops_cluster: True
  openshift_hosted_logging_testing: True
  openshift_docker_options: '--log-driver=journald'
  openshift_hosted_logging_use_journal: True
  openshift_deployment_type: $VARIANT
  openshift_hosted_logging_master_public_url: https://$fqdn:8443
  openshift_master_logging_public_url: https://$KIBANA_HOSTNAME
  openshift_hosted_logging_hostname: $KIBANA_HOSTNAME
  openshift_hosted_logging_ops_hostname: $KIBANA_OPS_HOSTNAME
  openshift_hosted_logging_elasticsearch_cluster_size: 1
  openshift_hosted_logging_image_version: $LOGGING_IMAGE_VERSION
  openshift_hosted_logging_image_prefix: $LOGGING_IMAGE_PREFIX
  openshift_hosted_logging_deployer_version: $LOGGING_IMAGE_VERSION
  openshift_hosted_logging_deployer_prefix: $LOGGING_IMAGE_PREFIX
  openshift_master_identity_providers: [{'name': 'allow_all', 'login': 'true', 'challenge': 'true', 'kind': 'AllowAllPasswordIdentityProvider'}]
  insecure_registry: $insecure_bool
  ansible_ssh_user: centos
  openshift_hosted_logging_test_user: kibuser
  openshift_hosted_logging_test_password: kibuser
  openshift_version: '$OPENSHIFT_VERSION'
  short_version: '$VARIANT_VERSION'
variant: $VARIANT
variant_version: '${VARIANT_VERSION}'
version: v2
EOF
}

if [ "$START_STEP" = create-inventory -o ! -f $inventory ] ; then
    pushd $OSHIFT_ANSIBLE_DIR/utils
    create_ooconfig > $ooconfig
    if [ ! -d oo-install ] ; then
        virtualenv oo-install
    fi
    . oo-install/bin/activate
    virtualenv --relocatable ./oo-install
    python setup.py clean
    python setup.py install
    rm -rf $HOME/.config/openshift/.ansible /tmp/ansible.log
    if [ -n "${PACKAGE_REPO:-}" ] ; then
        export OO_INSTALL_PUDDLE_REPO="${PACKAGE_REPO}"
    fi
    if [ -n "${INSECURE_REGISTRIES:-}" ] ; then
        export OO_INSTALL_INSECURE_REGISTRIES="${INSECURE_REGISTRIES:-}"
        export OO_INSTALL_ADDITIONAL_REGISTRIES="$OO_INSTALL_INSECURE_REGISTRIES"
    fi        
    oo-install -d -a $OSHIFT_ANSIBLE_DIR -c $ooconfig -v -u install --gen-inventory --force
    unset OO_INSTALL_PUDDLE_REPO OO_INSTALL_INSECURE_REGISTRIES OO_INSTALL_ADDITIONAL_REGISTRIES
    # https://github.com/openshift/openshift-ansible/pull/2910
    mv ~/.config/openshift/hosts $inventory
    deactivate
    popd
    START_STEP=install-openshift
fi

if [ "$START_STEP" = install-openshift ] ; then
    pushd $OSHIFT_ANSIBLE_DIR
    ansible-playbook -v -i $inventory playbooks/byo/openshift-cluster/config.yml
    popd
    START_STEP=install-logging
fi

fix_inventory_file() {
    # fix up hosts inventory file
    if grep \^openshift_deployment_type $inventory ; then
        return 0
    fi
    if [ -z "$fqdn" ] ; then
        fqdn=`get_remote_public_fqdn`
    fi
    sed -i '/^\[OSEv3:vars\]/,/^$/ {
/^$/i\
openshift_deployment_type='$VARIANT'
/^$/i\
openshift_hosted_logging_master_public_url=https://$fqdn:8443
/^$/i\
openshift_hosted_logging_hostname='$fqdn'
/^$/i\
openshift_hosted_logging_elasticsearch_cluster_size="1"
/^$/i\
openshift_hosted_logging_image_version='$LOGGING_IMAGE_VERSION'
/^$/i\
openshift_hosted_logging_image_prefix='$LOGGING_IMAGE_PREFIX'
/^$/i\
openshift_hosted_logging_deployer_version="'$LOGGING_IMAGE_VERSION'"
/^$/i\
openshift_hosted_logging_deployer_prefix='$LOGGING_IMAGE_PREFIX'
/^$/i\
insecure_registry='$insecure_bool'
}' $inventory
}

if [ "$START_STEP" = install-logging ] ; then
    fix_inventory_file
    if [ -z "$stack" ] ; then
        stack=`get_stack $STACK_NAME`
    fi
    if [ -z "$ip" ] ; then
        ip=`get_float $stack`
    fi
    if [ -z "$fqdn" ] ; then
        fqdn=`get_remote_public_fqdn`
    fi
    pushd $OSHIFT_ANSIBLE_DIR
    if [ ! -f openshift_hosted_logging_efk.yaml ] ; then
        ln -s playbooks/adhoc/openshift_hosted_logging_efk.yaml
    fi
    # HACK HACK HACK - there is a problem with selinux
    # type=AVC msg=audit(1465309048.442:38052): avc:  denied  { transition } for  pid=129662 comm="exe" path="/usr/bin/pod" dev="dm-1" ino=50425856 scontext=system_u:system_r:initrc_t:s0 tcontext=system_u:system_r:svirt_lxc_net_t:s0:c4,c7 tclass=process
    ssh $sshopts centos@$ip "sudo setenforce Permissive"
    ansible-playbook -v -i $inventory openshift_hosted_logging_efk.yaml
fi
