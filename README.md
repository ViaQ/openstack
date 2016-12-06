# Deploying OpenShift logging with OpenStack Heat and Ansible

This directory contains Heat templates, configs, and scripts for deploying
OpenShift with logging on OpenStack.

# Pre-requisites

### OpenStack CLI tools

You need to install the following packages: python-openstackclient
python2-openstacksdk python-novaclient python-heatclient python-neutronclient
python-glanceclient

This will provide commands such as `openstack`, `nova`, `heat`, etc.

### An OpenStack account

You need to have access to an OpenStack environment and project which allows
you to:

* Create/delete virtual machines and networks
* Create/run/delete Heat stacks
* Assign floating IP addresses

You will need to have an OPENRC file.  Here is an example, using Keystone V3
auth:
```
export OS_PROJECT_NAME=SomeProject
export OS_USERNAME=my-username
export OS_PASSWORD='my-password'
export OS_AUTH_URL="http://controller.oslab.openstack.test:5000/v3"
export OS_AUTH_STRATEGY=keystone
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
```

For example, put this in a file called `~/.openstackrc`

Before manually running any OpenStack CLI commands, you will need to source
this file.  If you do not want to "pollute" your shell environment, you can do
something like this:

`$ ( . ~/.openstackrc ; nova list ) | grep myusername`

You will need to create and add your SSH pubkey `nova keypair-add ...`

You will need a CentOS 7 image.  In the example files, the image
`centos-7-cloud` is used.  The image in your repo may be something else, or you
can add an image using `openstack image create`.  Use `openstack image list |
grep -i centos` to see if there are any CentOS 7 images available.

### Ansible

Install the `ansible` package.  The script uses the `ansible-playbook` command.

### OpenShift Ansible

Grab openshift-ansible from:
```
$ git clone https://github.com/openshift/openshift-ansible -b release-1.4
```

### Configure the properties.yaml file

The following properties should be edited:
* `flavor` - the smallest type of machine that will run everything - probably a
  medium or larger
* `key` - the name of the public key you added with `nova keypair-add ...`
* `public_network` - the default setting should be fine
* `image` - the name of your CentOS image - see above
* `run_stack_name` - the name of the Heat stack that will be created
* `oshift_hostname` - the external FQDN of your machine - this will also be
  used for the name of the Nova machine, as well as the hostname that Ansible
  will use, as well as the master public url of the OpenShift instance
  (i.e. the OpenShift UI will be at `https://oshift_hostname:8443`), as well as
  the default Kibana hostname.
* `kibana_hostname` - the external FQDN of Kibana
* `kibana_ops_hostname` - the external FQDN of Kibana - OPS cluster
* `es_hostname` - the external FQDN of Elasticsearch (for creating an external route)
* `es_ops_hostname` - the external FQDN of Elasticsearch - OPS cluster

The following properties probably do not have to be edited:
* `run_stack_file` - the name of the Heat stack yaml file to use
* `variant` - use `origin` (or `openshift-enterprise` if using Red Hat OCP)
* `variant_version` - major.minor version of OpenShift to use
* `openshift_version` - major.minor.patch version of OpenShift to use
* `logging_image_version` - version of logging images
* `logging_image_prefix` - logging image prefix

# Running

The `run-heat-ansible` script is the main entry point.  It uses the following
environment variables:
* `OPENRC` - Required - the OPENRC file you created above e.g. `~/.openstackrc`
* `START_STEP` - Required - which step to start with
  * `clean` - delete everything and start over
  * `create` - create the VM
  * `fqdn` - get the FQDN and floating IP of the machine and set up `/etc/hosts`
  * `create-inventory` - create the Ansible inventory file
  * `install-openshift` - install OpenShift using Ansible
  * `install-logging` - install OpenShift aggregated logging
* `ANSIBLE_LOG_PATH` - Optional - dump a copy of the Ansible logs to this file

For example:
```
ANSIBLE_LOG_PATH=/tmp/ansible.log START_STEP=clean OPENRC=~/.openstackrc \
    ./run-heat-ansible.sh properties-origin14.yaml 2>&1 | tee run.log
```

Once this completes, you should be able to ssh into the `oshift_hostname` as
the `centos` user.  You should also be able to run Kibana, but you will need to
create a user first.  The install above uses the
`AllowAllPasswordIdentityProvider` which makes it easy to create test users like
this:

    # ssh myuser@$oshift_hostname
    # oc project logging
    # oc login --username=kibtest --password=kibtest
    # oc login --username=system:admin
    # oadm policy add-cluster-role-to-user cluster-admin kibtest

Now you can use the `kibtest` username and password to access Kibana.  Just
point your web browser at `https://hostname` where the hostname is the hostname
you specified in `kibana_hostname` or `kibana_ops_hostname` in your properties
file.
