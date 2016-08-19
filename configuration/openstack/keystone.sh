#!/bin/bash

display_var TRIX_CTRL_HOSTNAME

function error {
    mysqladmin -uroot -p$MYSQL_ROOT_PASSWORD drop keystone || true
    rm -f /etc/httpd/conf.d/wsgi-keystone.conf || true
    rm -f /root/.admin-openrc || true
    systemctl kill -s SIGKILL httpd.service || true
    exit 1
}

trap error ERR

KEYSTONE_ADMIN_TOKEN=$(openssl rand -hex 10)
KEYSTONE_DB_PW="$(get_password "$KEYSTONE_DB_PW")"
ADMIN_PW="$(get_password "$ADMIN_PW")"

# Setup database
echo_info "Setting up a database for keystone"

mysql -u root -p$MYSQL_ROOT_PASSWORD <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO "keystone"@"localhost" \
  IDENTIFIED BY "${KEYSTONE_DB_PW}";
GRANT ALL PRIVILEGES ON keystone.* TO "keystone"@"%" \
  IDENTIFIED BY "${KEYSTONE_DB_PW}";
EOF

openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token $KEYSTONE_ADMIN_TOKEN
openstack-config --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:${KEYSTONE_DB_PW}@127.0.0.1/keystone"
openstack-config --set /etc/keystone/keystone.conf token provider fernet

echo_info "Initializing the keystone database"
su -s /bin/sh -c "keystone-manage db_sync" keystone

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone

# Configure httpd-wsgi
echo_info "Setting up httpd and memcached"

sed -i "1s,^,ServerName $TRIX_CTRL_HOSTNAME," /etc/httpd/conf/httpd.conf
cp -v ${POST_FILEDIR}/wsgi-keystone.conf /etc/httpd/conf.d/wsgi-keystone.conf

# Start services
systemctl enable memcached.service
systemctl enable httpd.service

systemctl start memcached.service
systemctl start httpd.service

# Create service, endpoints, users and roles
echo_info "Creating keystone service, endpoints, users and roles"

export OS_TOKEN=$KEYSTONE_ADMIN_TOKEN
export OS_URL=http://${TRIX_CTRL_HOSTNAME}:35357/v3
export OS_IDENTITY_API_VERSION=3

openstack service create --name keystone --description "OpenStack Identity" identity

openstack endpoint create --region RegionOne identity public http://${TRIX_CTRL_HOSTNAME}:5000/v3
openstack endpoint create --region RegionOne identity internal http://${TRIX_CTRL_HOSTNAME}:5000/v3
openstack endpoint create --region RegionOne identity admin http://${TRIX_CTRL_HOSTNAME}:35357/v3

openstack domain create --description "Default Domain" default

openstack project create --domain default --description "Admin Project" admin
openstack user create --domain default --password $ADMIN_PW admin
openstack role create admin
openstack role add --project admin --user admin admin

openstack project create --domain default --description "Service Project" service
openstack role create user

unset OS_TOKEN OS_URL

# Setup openstack admin credentials file
cp -v ${POST_FILEDIR}/.admin-openrc /root/.admin-openrc
chmod 500 /root/.admin-openrc

sed -ie "s,{{ adminPW }},$ADMIN_PW," /root/.admin-openrc
sed -ie "s,{{ controller }},$TRIX_CTRL_HOSTNAME," /root/.admin-openrc

# Disable keystone admin_token
echo_info "Disabling the keystone admin token"

PIPELINE=$(openstack-config --get /etc/keystone/keystone-paste.ini pipeline:public_api pipeline)
openstack-config --set /etc/keystone/keystone-paste.ini pipeline:public_api pipeline "$(echo $PIPELINE | sed "s,^\(.*\)admin_token_auth \(.*\)$,\1\2,")"

PIPELINE=$(openstack-config --get /etc/keystone/keystone-paste.ini pipeline:admin_api pipeline)
openstack-config --set /etc/keystone/keystone-paste.ini pipeline:admin_api pipeline "$(echo $PIPELINE | sed "s,^\(.*\)admin_token_auth \(.*\)$,\1\2,")"

PIPELINE=$(openstack-config --get /etc/keystone/keystone-paste.ini pipeline:api_v3 pipeline)
openstack-config --set /etc/keystone/keystone-paste.ini pipeline:api_v3 pipeline "$(echo $PIPELINE | sed "s,^\(.*\)admin_token_auth \(.*\)$,\1\2,")"

echo_info "Saving passwords"
store_password KEYSTONE_DB_PW $KEYSTONE_DB_PW
store_password ADMIN_PW $ADMIN_PW
