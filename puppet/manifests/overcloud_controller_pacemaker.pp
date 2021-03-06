# Copyright 2015 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

Pcmk_resource <| |> {
  tries     => 10,
  try_sleep => 3,
}

if !str2bool(hiera('enable_package_install', 'false')) {
  case $::osfamily {
    'RedHat': {
      Package { provider => 'norpm' } # provided by tripleo-puppet
    }
    default: {
      warning('enable_package_install option not supported.')
    }
  }
}

if $::hostname == downcase(hiera('bootstrap_nodeid')) {
  $pacemaker_master = true
  $sync_db = true
} else {
  $pacemaker_master = false
  $sync_db = false
}

# When to start and enable services which haven't been Pacemakerized
# FIXME: remove when we start all OpenStack services using Pacemaker
# (occurences of this variable will be gradually replaced with false)
$non_pcmk_start = hiera('step') >= 4

if hiera('step') >= 1 {

  create_resources(sysctl::value, hiera('sysctl_settings'), {})

  if count(hiera('ntp::servers')) > 0 {
    include ::ntp
  }

  $controller_node_ips = split(hiera('controller_node_ips'), ',')
  $controller_node_names = split(downcase(hiera('controller_node_names')), ',')
  class { '::tripleo::loadbalancer' :
    controller_hosts       => $controller_node_ips,
    controller_hosts_names => $controller_node_names,
    manage_vip             => false,
    haproxy_service_manage => false,
  }

  $pacemaker_cluster_members = downcase(regsubst(hiera('controller_node_names'), ',', ' ', 'G'))
  user { 'hacluster':
   ensure => present,
  } ->
  class { '::pacemaker':
    hacluster_pwd => hiera('hacluster_pwd'),
  } ->
  class { '::pacemaker::corosync':
    cluster_members => $pacemaker_cluster_members,
    setup_cluster   => $pacemaker_master,
  }
  class { '::pacemaker::stonith':
    disable => true,
  }

  # Only configure RabbitMQ in this step, don't start it yet to
  # avoid races where non-master nodes attempt to start without
  # config (eg. binding on 0.0.0.0)
  # The module ignores erlang_cookie if cluster_config is false
  class { '::rabbitmq':
    service_manage          => false,
    tcp_keepalive           => false,
    config_kernel_variables => hiera('rabbitmq_kernel_variables'),
    config_variables        => hiera('rabbitmq_config_variables'),
    environment_variables   => hiera('rabbitmq_environment'),
  } ->
  file { '/var/lib/rabbitmq/.erlang.cookie':
    ensure  => 'present',
    owner   => 'rabbitmq',
    group   => 'rabbitmq',
    mode    => '0400',
    content => hiera('rabbitmq::erlang_cookie'),
    replace => true,
  }

  if downcase(hiera('ceilometer_backend')) == 'mongodb' {
    include ::mongodb::globals
    # FIXME: replace with service_manage => false on ::mongodb::server
    # when this is merged: https://github.com/puppetlabs/pupp etlabs-mongodb/pull/198
    class { '::mongodb::server' :
      service_ensure => undef,
      service_enable => false,
    }
  }

  # Memcached
  class {'::memcached' :
    service_manage => false,
  }

  # Galera
  if str2bool(hiera('enable_galera', 'true')) {
    $mysql_config_file = '/etc/my.cnf.d/galera.cnf'
  } else {
    $mysql_config_file = '/etc/my.cnf.d/server.cnf'
  }
  $galera_nodes = downcase(hiera('galera_node_names', $::hostname))
  $galera_nodes_count = count(split($galera_nodes, ','))

  $mysqld_options = {
    'mysqld' => {
      'skip-name-resolve'             => '1',
      'binlog_format'                 => 'ROW',
      'default-storage-engine'        => 'innodb',
      'innodb_autoinc_lock_mode'      => '2',
      'innodb_locks_unsafe_for_binlog'=> '1',
      'query_cache_size'              => '0',
      'query_cache_type'              => '0',
      'bind-address'                  => hiera('mysql_bind_host'),
      'max_connections'               => '1024',
      'open_files_limit'              => '-1',
      'wsrep_provider'                => '/usr/lib64/galera/libgalera_smm.so',
      'wsrep_cluster_name'            => 'galera_cluster',
      'wsrep_slave_threads'           => '1',
      'wsrep_certify_nonPK'           => '1',
      'wsrep_max_ws_rows'             => '131072',
      'wsrep_max_ws_size'             => '1073741824',
      'wsrep_debug'                   => '0',
      'wsrep_convert_LOCK_to_trx'     => '0',
      'wsrep_retry_autocommit'        => '1',
      'wsrep_auto_increment_control'  => '1',
      'wsrep_drupal_282555_workaround'=> '0',
      'wsrep_causal_reads'            => '0',
      'wsrep_notify_cmd'              => '',
      'wsrep_sst_method'              => 'rsync',
    }
  }

  class { '::mysql::server':
    create_root_user   => false,
    create_root_my_cnf => false,
    config_file        => $mysql_config_file,
    override_options   => $mysqld_options,
    service_manage     => false,
  }

}

if hiera('step') >= 2 {

  if $pacemaker_master {
    $control_vip = hiera('tripleo::loadbalancer::controller_virtual_ip')
    pacemaker::resource::ip { 'control_vip':
      ip_address => $control_vip,
    }
    $public_vip = hiera('tripleo::loadbalancer::public_virtual_ip')
    pacemaker::resource::ip { 'public_vip':
      ip_address => $public_vip,
    }
    pacemaker::resource::service { 'haproxy':
      clone_params => true,
    }
    pacemaker::resource::service { $::memcached::params::service_name :
      clone_params => true,
      require      => Class['::memcached'],
    }

    pacemaker::resource::ocf { 'rabbitmq':
      ocf_agent_name  => 'heartbeat:rabbitmq-cluster',
      resource_params => 'set_policy=\'ha-all ^(?!amq\.).* {"ha-mode":"all"}\'',
      clone_params    => 'ordered=true interleave=true',
      require         => Class['::rabbitmq'],
    }

    if downcase(hiera('ceilometer_backend')) == 'mongodb' {
      pacemaker::resource::service { $::mongodb::params::service_name :
        op_params    => 'start timeout=120s',
        clone_params => true,
        require      => Class['::mongodb::server'],
        before       => Exec['mongodb-ready'],
      }
      # NOTE (spredzy) : The replset can only be run
      # once all the nodes have joined the cluster.
      $mongo_node_ips = split(hiera('mongo_node_ips'), ',')
      $mongo_node_ips_with_port = suffix($mongo_node_ips, ':27017')
      $mongo_node_string = join($mongo_node_ips_with_port, ',')
      $mongodb_replset = hiera('mongodb::server::replset')
      $mongodb_cluster_ready_command = join(suffix(prefix($mongo_node_ips, '/bin/nc -w1 '), ' 27017 < /dev/null'), ' && ')
      $mongodb_pacemaker_resource = Pacemaker::Resource::Service[$::mongodb::params::service_name]
      exec { 'mongodb-ready' :
        command   => $mongodb_cluster_ready_command,
        timeout   => 30,
        tries     => 180,
        try_sleep => 10,
      }
      mongodb_replset { $mongodb_replset :
        members => $mongo_node_ips_with_port,
        require => Exec['mongodb-ready'],
      }
    }

    pacemaker::resource::ocf { 'galera' :
      ocf_agent_name  => 'heartbeat:galera',
      op_params       => 'promote timeout=300s on-fail=block',
      master_params   => '',
      meta_params     => "master-max=${galera_nodes_count} ordered=true",
      resource_params => "additional_parameters='--open-files-limit=16384' enable_creation=true wsrep_cluster_address='gcomm://${galera_nodes}'",
      require         => Class['::mysql::server'],
      before          => Exec['galera-ready'],
    }
  }

  # Redis
  $redis_node_ips = split(hiera('redis_node_ips'), ',')
  $redis_master_hostname = downcase(hiera('bootstrap_nodeid'))

  if $redis_master_hostname == $::hostname {
    $slaveof = undef
  } else {
    $slaveof = "${redis_master_hostname} 6379"
  }
  class {'::redis' :
    slaveof => $slaveof,
  }

  if count($redis_node_ips) > 1 {
    Class['::tripleo::redis_notification'] -> Service['redis-sentinel']
    include ::redis::sentinel
    class {'::tripleo::redis_notification' :
      haproxy_monitor_ip => hiera('tripleo::loadbalancer::controller_virtual_ip'),
    }
  }

  exec { 'galera-ready' :
    command     => '/usr/bin/clustercheck >/dev/null',
    timeout     => 30,
    tries       => 180,
    try_sleep   => 10,
    environment => ["AVAILABLE_WHEN_READONLY=0"],
    require     => File['/etc/sysconfig/clustercheck'],
  }

  file { '/etc/sysconfig/clustercheck' :
    ensure  => file,
    content => "MYSQL_USERNAME=root\n
MYSQL_PASSWORD=''\n
MYSQL_HOST=localhost\n",
  }

  xinetd::service { 'galera-monitor' :
    port           => '9200',
    server         => '/usr/bin/clustercheck',
    per_source     => 'UNLIMITED',
    log_on_success => '',
    log_on_failure => 'HOST',
    flags          => 'REUSE',
    service_type   => 'UNLISTED',
    user           => 'root',
    group          => 'root',
    require        => File['/etc/sysconfig/clustercheck'],
  }

  # Create all the database schemas
  # Example DSN format: mysql://user:password@host/dbname
  if $sync_db {
    $allowed_hosts = ['%',hiera('mysql_bind_host')]
    $keystone_dsn = split(hiera('keystone::database_connection'), '[@:/?]')
    class { 'keystone::db::mysql':
      user          => $keystone_dsn[3],
      password      => $keystone_dsn[4],
      host          => $keystone_dsn[5],
      dbname        => $keystone_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    $glance_dsn = split(hiera('glance::api::database_connection'), '[@:/?]')
    class { 'glance::db::mysql':
      user          => $glance_dsn[3],
      password      => $glance_dsn[4],
      host          => $glance_dsn[5],
      dbname        => $glance_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    $nova_dsn = split(hiera('nova::database_connection'), '[@:/?]')
    class { 'nova::db::mysql':
      user          => $nova_dsn[3],
      password      => $nova_dsn[4],
      host          => $nova_dsn[5],
      dbname        => $nova_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    $neutron_dsn = split(hiera('neutron::server::database_connection'), '[@:/?]')
    class { 'neutron::db::mysql':
      user          => $neutron_dsn[3],
      password      => $neutron_dsn[4],
      host          => $neutron_dsn[5],
      dbname        => $neutron_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    $cinder_dsn = split(hiera('cinder::database_connection'), '[@:/?]')
    class { 'cinder::db::mysql':
      user          => $cinder_dsn[3],
      password      => $cinder_dsn[4],
      host          => $cinder_dsn[5],
      dbname        => $cinder_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    $heat_dsn = split(hiera('heat::database_connection'), '[@:/?]')
    class { 'heat::db::mysql':
      user          => $heat_dsn[3],
      password      => $heat_dsn[4],
      host          => $heat_dsn[5],
      dbname        => $heat_dsn[6],
      allowed_hosts => $allowed_hosts,
      require       => Exec['galera-ready'],
    }
    if downcase(hiera('ceilometer_backend')) == 'mysql' {
      $ceilometer_dsn = split(hiera('ceilometer_mysql_conn_string'), '[@:/?]')
      class { 'ceilometer::db::mysql':
        user          => $ceilometer_dsn[3],
        password      => $ceilometer_dsn[4],
        host          => $ceilometer_dsn[5],
        dbname        => $ceilometer_dsn[6],
        allowed_hosts => $allowed_hosts,
        require       => Exec['galera-ready'],
      }
    }
  }

  # pre-install swift here so we can build rings
  include ::swift

  # Ceph
  $cinder_enable_rbd_backend = hiera('cinder_enable_rbd_backend', false)
  $enable_ceph = $cinder_enable_rbd_backend

  if $enable_ceph {
    class { 'ceph::profile::params':
      mon_initial_members => downcase(hiera('ceph_mon_initial_members'))
    }
    include ::ceph::profile::mon
  }

  if str2bool(hiera('enable_ceph_storage', 'false')) {
    include ::ceph::profile::client
    include ::ceph::profile::osd
  }


} #END STEP 2

if hiera('step') >= 3 {

  class { '::keystone':
    sync_db => $sync_db,
    manage_service => false,
    enabled => false,
  }

  #TODO: need a cleanup-keystone-tokens.sh solution here
  keystone_config {
    'ec2/driver': value => 'keystone.contrib.ec2.backends.sql.Ec2';
  }
  file { [ '/etc/keystone/ssl', '/etc/keystone/ssl/certs', '/etc/keystone/ssl/private' ]:
    ensure  => 'directory',
    owner   => 'keystone',
    group   => 'keystone',
    require => Package['keystone'],
  }
  file { '/etc/keystone/ssl/certs/signing_cert.pem':
    content => hiera('keystone_signing_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }
  file { '/etc/keystone/ssl/private/signing_key.pem':
    content => hiera('keystone_signing_key'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/private'],
  }
  file { '/etc/keystone/ssl/certs/ca.pem':
    content => hiera('keystone_ca_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }

  $glance_backend = downcase(hiera('glance_backend', 'swift'))
  case $glance_backend {
      swift: { $glance_store = 'glance.store.swift.Store' }
      file: { $glance_store = 'glance.store.filesystem.Store' }
      rbd: { $glance_store = 'glance.store.rbd.Store' }
      default: { fail('Unrecognized glance_backend parameter.') }
  }

  # TODO: notifications, scrubber, etc.
  include ::glance
  class { 'glance::api':
    known_stores => [$glance_store],
    manage_service => false,
    enabled => false,
  }
  class { '::glance::registry' :
    sync_db => $sync_db,
    manage_service => false,
    enabled => false,
  }
  include join(['::glance::backend::', $glance_backend])

  class { 'nova':
    glance_api_servers     => join([hiera('glance_protocol'), '://', hiera('controller_virtual_ip'), ':', hiera('glance_port')]),
  }

  class { '::nova::api' :
    sync_db => $sync_db,
    manage_service => false,
    enabled => false,
  }
  class { '::nova::cert' :
    manage_service => false,
    enabled => false,
  }
  class { '::nova::conductor' :
    manage_service => false,
    enabled => false,
  }
  class { '::nova::consoleauth' :
    manage_service => false,
    enabled => false,
  }
  class { '::nova::vncproxy' :
    manage_service => false,
    enabled => false,
  }
  class { '::nova::scheduler' :
    manage_service => false,
    enabled => false,
  }
  include ::nova::network::neutron

  # Neutron class definitions
  include ::neutron
  class { '::neutron::server' :
    sync_db => $sync_db,
    manage_service => false,
    enabled => false,
  }
  class { '::neutron::agents::dhcp' :
    manage_service => false,
    enabled => false,
  }
  class { '::neutron::agents::l3' :
    manage_service => false,
    enabled => false,
  }
  class { 'neutron::agents::metadata':
    auth_url => join(['http://', hiera('controller_virtual_ip'), ':35357/v2.0']),
    manage_service => false,
    enabled => false,
  }
  file { '/etc/neutron/dnsmasq-neutron.conf':
    content => hiera('neutron_dnsmasq_options'),
    owner   => 'neutron',
    group   => 'neutron',
    notify  => Service['neutron-dhcp-service'],
    require => Package['neutron'],
  }
  class { 'neutron::plugins::ml2':
    flat_networks   => split(hiera('neutron_flat_networks'), ','),
    tenant_network_types => [hiera('neutron_tenant_network_type')],
    type_drivers    => [hiera('neutron_tenant_network_type')],
  }
  class { 'neutron::agents::ml2::ovs':
    # manage_service   => false # not implemented
    enabled          => false,
    bridge_mappings  => split(hiera('neutron_bridge_mappings'), ','),
    tunnel_types     => split(hiera('neutron_tunnel_types'), ','),
  }


  include ::cinder
  class { '::cinder::api':
    sync_db => $sync_db,
    manage_service => false,
    enabled => false,
  }
  class { '::cinder::scheduler' :
    manage_service => false,
    enabled => false,
  }
  class { '::cinder::volume' :
    manage_service => false,
    enabled => false,
  }
  include ::cinder::glance
  class {'cinder::setup_test_volume':
    size => join([hiera('cinder_lvm_loop_device_size'), 'M']),
  }

  $cinder_enable_iscsi = hiera('cinder_enable_iscsi_backend', true)
  if $cinder_enable_iscsi {
    $cinder_iscsi_backend = 'tripleo_iscsi'

    cinder::backend::iscsi { $cinder_iscsi_backend :
      iscsi_ip_address => hiera('cinder_iscsi_ip_address'),
      iscsi_helper     => hiera('cinder_iscsi_helper'),
    }
  }

  if $enable_ceph {

    Ceph_pool {
      pg_num  => hiera('ceph::profile::params::osd_pool_default_pg_num'),
      pgp_num => hiera('ceph::profile::params::osd_pool_default_pgp_num'),
      size    => hiera('ceph::profile::params::osd_pool_default_size'),
    }

    $ceph_pools = hiera('ceph_pools')
    ceph::pool { $ceph_pools : }
  }

  if $cinder_enable_rbd_backend {
    $cinder_rbd_backend = 'tripleo_ceph'

    cinder_config {
      "${cinder_rbd_backend}/host": value => 'hostgroup';
    }

    cinder::backend::rbd { $cinder_rbd_backend :
      rbd_pool        => 'volumes',
      rbd_user        => 'openstack',
      rbd_secret_uuid => hiera('ceph::profile::params::fsid'),
      require         => Ceph::Pool['volumes'],
    }
  }

  $cinder_enabled_backends = delete_undef_values([$cinder_iscsi_backend, $cinder_rbd_backend])
  class { '::cinder::backends' :
    enabled_backends => $cinder_enabled_backends,
  }

  # swift proxy
  class { '::swift::proxy' :
    manage_service => $non_pcmk_start,
    enabled => $non_pcmk_start,
  }
  include ::swift::proxy::proxy_logging
  include ::swift::proxy::healthcheck
  include ::swift::proxy::cache
  include ::swift::proxy::keystone
  include ::swift::proxy::authtoken
  include ::swift::proxy::staticweb
  include ::swift::proxy::ceilometer
  include ::swift::proxy::ratelimit
  include ::swift::proxy::catch_errors
  include ::swift::proxy::tempurl
  include ::swift::proxy::formpost

  # swift storage
  if str2bool(hiera('enable_swift_storage', 'true')) {
    class {'::swift::storage::all':
      mount_check => str2bool(hiera('swift_mount_check'))
    }
    class {'::swift::storage::account':
      manage_service => $non_pcmk_start,
      enabled => $non_pcmk_start,
    }
    class {'::swift::storage::container':
      manage_service => $non_pcmk_start,
      enabled => $non_pcmk_start,
    }
    class {'::swift::storage::object':
      manage_service => $non_pcmk_start,
      enabled => $non_pcmk_start,
    }
    if(!defined(File['/srv/node'])) {
      file { '/srv/node':
        ensure  => directory,
        owner   => 'swift',
        group   => 'swift',
        require => Package['openstack-swift'],
      }
    }
    $swift_components = ['account', 'container', 'object']
    swift::storage::filter::recon { $swift_components : }
    swift::storage::filter::healthcheck { $swift_components : }
  }

  # Ceilometer
  $ceilometer_backend = downcase(hiera('ceilometer_backend'))
  case $ceilometer_backend {
    /mysql/ : {
      $ceilometer_database_connection = hiera('ceilometer_mysql_conn_string')
    }
    default : {
      $ceilometer_database_connection = "mongodb://${mongo_node_string}/ceilometer?replicaSet=${mongodb_replset}"
    }
  }
  include ::ceilometer
  class { '::ceilometer::api' :
    manage_service => false,
    enabled => false,
  }
  class { '::ceilometer::agent::notification' :
    manage_service => false,
    enabled => false,
  }
  class { '::ceilometer::agent::central' :
    manage_service => false,
    enabled => false,
  }
  class { '::ceilometer::alarm::notifier' :
    manage_service => false,
    enabled => false,
  }
  class { '::ceilometer::alarm::evaluator' :
    manage_service => false,
    enabled => false,
  }
  class { '::ceilometer::collector' :
    manage_service => false,
    enabled => false,
  }
  include ::ceilometer::expirer
  class { '::ceilometer::db' :
    database_connection => $ceilometer_database_connection,
    sync_db             => $sync_db,
  }
  class { 'ceilometer::agent::auth':
    auth_url => join(['http://', hiera('controller_virtual_ip'), ':5000/v2.0']),
  }

  Cron <| title == 'ceilometer-expirer' |> { command => "sleep $((\$(od -A n -t d -N 3 /dev/urandom) % 86400)) && ${::ceilometer::params::expirer_command}" }

  # Heat
  class { '::heat' :
    sync_db => $sync_db,
  }
  class { '::heat::api' :
    manage_service => false,
    enabled => false,
  }
  class { '::heat::api_cfn' :
    manage_service => false,
    enabled => false,
  }
  class { '::heat::api_cloudwatch' :
    manage_service => false,
    enabled => false,
  }
  class { '::heat::engine' :
    manage_service => false,
    enabled => false,
  }

  # Horizon
  $vhost_params = { add_listen => false }
  class { 'horizon':
    cache_server_ip    => split(hiera('memcache_node_ips', '127.0.0.1'), ','),
    vhost_extra_params => $vhost_params,
  }

  $snmpd_user = hiera('snmpd_readonly_user_name')
  snmp::snmpv3_user { $snmpd_user:
    authtype => 'MD5',
    authpass => hiera('snmpd_readonly_user_password'),
  }
  class { 'snmp':
    agentaddress => ['udp:161','udp6:[::1]:161'],
    snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
  }

} #END STEP 3

if hiera('step') >= 4 {
  if $pacemaker_master {

    # Keystone
    pacemaker::resource::service { $::keystone::params::service_name :
      clone_params => "interleave=true",
    }

    # Cinder
    pacemaker::resource::service { $::cinder::params::api_service :
      clone_params => "interleave=true",
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    pacemaker::resource::service { $::cinder::params::scheduler_service :
      clone_params => "interleave=true",
    }
    pacemaker::resource::service { $::cinder::params::volume_service : }

    pacemaker::constraint::base { 'keystone-then-cinder-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::cinder::params::api_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'cinder-api-then-cinder-scheduler-constraint':
      constraint_type => "order",
      first_resource => "${::cinder::params::api_service}-clone",
      second_resource => "${::cinder::params::scheduler_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                  Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::colocation { 'cinder-scheduler-with-cinder-api-colocation':
      source => "${::cinder::params::scheduler_service}-clone",
      target => "${::cinder::params::api_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                  Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::base { 'cinder-scheduler-then-cinder-volume-constraint':
      constraint_type => "order",
      first_resource => "${::cinder::params::scheduler_service}-clone",
      second_resource => "${::cinder::params::volume_service}",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                  Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }
    pacemaker::constraint::colocation { 'cinder-volume-with-cinder-scheduler-colocation':
      source => "${::cinder::params::volume_service}",
      target => "${::cinder::params::scheduler_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                  Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }

    # Glance
    pacemaker::resource::service { $::glance::params::registry_service_name :
      clone_params => "interleave=true",
      require      => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    pacemaker::resource::service { $::glance::params::api_service_name :
      clone_params => "interleave=true",
    }

    pacemaker::constraint::base { 'keystone-then-glance-registry-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::glance::params::registry_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'glance-registry-then-glance-api-constraint':
      constraint_type => "order",
      first_resource  => "${::glance::params::registry_service_name}-clone",
      second_resource => "${::glance::params::api_service_name}-clone",
      first_action    => "start",
      second_action   => "start",
      require => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                  Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'glance-api-with-glance-registry-colocation':
      source  => "${::glance::params::api_service_name}-clone",
      target  => "${::glance::params::registry_service_name}-clone",
      score   => "INFINITY",
      require => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                  Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }

    # Neutron
    pacemaker::resource::service { $::neutron::params::server_service:
      op_params => "start timeout=90",
      clone_params   => "interleave=true",
      require => Pacemaker::Resource::Service[$::keystone::params::service_name]
    }
    pacemaker::resource::service { $::neutron::params::l3_agent_service:
      clone_params   => "interleave=true",
    }
    pacemaker::resource::service { $::neutron::params::dhcp_agent_service:
      clone_params   => "interleave=true",
    }
    pacemaker::resource::service { $::neutron::params::ovs_agent_service:
      clone_params => "interleave=true",
    }
    pacemaker::resource::service { $::neutron::params::metadata_agent_service:
      clone_params => "interleave=true",
    }
    pacemaker::resource::ocf { $::neutron::params::ovs_cleanup_service:
      ocf_agent_name => "neutron:OVSCleanup",
      clone_params => "interleave=true",
    }
    pacemaker::resource::ocf { 'neutron-netns-cleanup':
      ocf_agent_name => "neutron:NetnsCleanup",
      clone_params => "interleave=true",
    }
    pacemaker::resource::ocf { 'neutron-scale':
      ocf_agent_name => "neutron:NeutronScale",
      clone_params => "globally-unique=true clone-max=3 interleave=true",
    }
    pacemaker::constraint::base { 'keystone-to-neutron-server-constraint':
      constraint_type => "order",
      first_resource => "${::keystone::params::service_name}-clone",
      second_resource => "${::neutron::params::server_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service[$::keystone::params::service_name],
                  Pacemaker::Resource::Service[$::neutron::params::server_service]],
    }
    pacemaker::constraint::base { 'neutron-server-to-neutron-scale-constraint':
      constraint_type => "order",
      first_resource => "${::neutron::params::server_service}-clone",
      second_resource => "neutron-scale-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                  Pacemaker::Resource::Ocf['neutron-scale']],
    }
    pacemaker::constraint::base { 'neutron-scale-to-ovs-cleanup-constraint':
      constraint_type => "order",
      first_resource => "neutron-scale-clone",
      second_resource => "${::neutron::params::ovs_cleanup_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Ocf['neutron-scale'],
                  Pacemaker::Resource::Ocf["${::neutron::params::ovs_cleanup_service}"]],
    }
    pacemaker::constraint::colocation { 'neutron-scale-to-ovs-cleanup-colocation':
      source => "${::neutron::params::ovs_cleanup_service}-clone",
      target => "neutron-scale-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Ocf['neutron-scale'],
                  Pacemaker::Resource::Ocf["${::neutron::params::ovs_cleanup_service}"]],
    }
    pacemaker::constraint::base { 'neutron-ovs-cleanup-to-netns-cleanup-constraint':
      constraint_type => "order",
      first_resource => "${::neutron::params::ovs_cleanup_service}-clone",
      second_resource => "neutron-netns-cleanup-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Ocf["${::neutron::params::ovs_cleanup_service}"],
                  Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
    }
    pacemaker::constraint::colocation { 'neutron-ovs-cleanup-to-netns-cleanup-colocation':
      source => "neutron-netns-cleanup-clone",
      target => "${::neutron::params::ovs_cleanup_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Ocf["${::neutron::params::ovs_cleanup_service}"],
                  Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
    }
    pacemaker::constraint::base { 'neutron-netns-cleanup-to-openvswitch-agent-constraint':
      constraint_type => "order",
      first_resource => "neutron-netns-cleanup-clone",
      second_resource => "${::neutron::params::ovs_agent_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Ocf["neutron-netns-cleanup"],
                  Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}"]],
    }
    pacemaker::constraint::colocation { 'neutron-netns-cleanup-to-openvswitch-agent-colocation':
      source => "${::neutron::params::ovs_agent_service}-clone",
      target => "neutron-netns-cleanup-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Ocf["neutron-netns-cleanup"],
                  Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}"]],
    }
    pacemaker::constraint::base { 'neutron-openvswitch-agent-to-dhcp-agent-constraint':
      constraint_type => "order",
      first_resource => "${::neutron::params::ovs_agent_service}-clone",
      second_resource => "${::neutron::params::dhcp_agent_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::dhcp_agent_service}"]],

    }
    pacemaker::constraint::colocation { 'neutron-openvswitch-agent-to-dhcp-agent-colocation':
      source => "${::neutron::params::dhcp_agent_service}-clone",
      target => "${::neutron::params::ovs_agent_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service["${::neutron::params::ovs_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::dhcp_agent_service}"]],
    }
    pacemaker::constraint::base { 'neutron-dhcp-agent-to-l3-agent-constraint':
      constraint_type => "order",
      first_resource => "${::neutron::params::dhcp_agent_service}-clone",
      second_resource => "${::neutron::params::l3_agent_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service["${::neutron::params::dhcp_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::l3_agent_service}"]]
    }
    pacemaker::constraint::colocation { 'neutron-dhcp-agent-to-l3-agent-colocation':
      source => "${::neutron::params::l3_agent_service}-clone",
      target => "${::neutron::params::dhcp_agent_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service["${::neutron::params::dhcp_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::l3_agent_service}"]]
    }
    pacemaker::constraint::base { 'neutron-l3-agent-to-metadata-agent-constraint':
      constraint_type => "order",
      first_resource => "${::neutron::params::l3_agent_service}-clone",
      second_resource => "${::neutron::params::metadata_agent_service}-clone",
      first_action => "start",
      second_action => "start",
      require => [Pacemaker::Resource::Service["${::neutron::params::l3_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::metadata_agent_service}"]]
    }
    pacemaker::constraint::colocation { 'neutron-l3-agent-to-metadata-agent-colocation':
      source => "${::neutron::params::metadata_agent_service}-clone",
      target => "${::neutron::params::l3_agent_service}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service["${::neutron::params::l3_agent_service}"],
                  Pacemaker::Resource::Service["${::neutron::params::metadata_agent_service}"]]
    }

    # Nova
    pacemaker::resource::service { $::nova::params::api_service_name :
      clone_params    => "interleave=true",
      op_params       => "monitor start-delay=10s",
    }
    pacemaker::resource::service { $::nova::params::conductor_service_name :
      clone_params    => "interleave=true",
      op_params       => "monitor start-delay=10s",
    }
    pacemaker::resource::service { $::nova::params::consoleauth_service_name :
      clone_params    => "interleave=true",
      op_params       => "monitor start-delay=10s",
      require         => Pacemaker::Resource::Service[$::keystone::params::service_name],
    }
    pacemaker::resource::service { $::nova::params::vncproxy_service_name :
      clone_params    => "interleave=true",
      op_params       => "monitor start-delay=10s",
    }
    pacemaker::resource::service { $::nova::params::scheduler_service_name :
      clone_params    => "interleave=true",
      op_params       => "monitor start-delay=10s",
    }

    pacemaker::constraint::base { 'keystone-then-nova-consoleauth-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::nova::params::consoleauth_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }
    pacemaker::constraint::base { 'nova-consoleauth-then-nova-vncproxy-constraint':
      constraint_type => "order",
      first_resource  => "${::nova::params::consoleauth_service_name}-clone",
      second_resource => "${::nova::params::vncproxy_service_name}-clone",
      first_action    => "start",
      second_action   => "start",
      require => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                  Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-vncproxy-with-nova-consoleauth-colocation':
      source => "${::nova::params::vncproxy_service_name}-clone",
      target => "${::nova::params::consoleauth_service_name}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                  Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    # FIXME(gfidente): novncproxy will not start unless websockify is updated to 0.6
    # which is not the case for f20 nor f21; ucomment when it becomes available
    #pacemaker::constraint::base { 'nova-vncproxy-then-nova-api-constraint':
    #  constraint_type => "order",
    #  first_resource  => "${::nova::params::vncproxy_service_name}-clone",
    #  second_resource => "${::nova::params::api_service_name}-clone",
    #  first_action    => "start",
    #  second_action   => "start",
    #  require => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
    #              Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    #}
    #pacemaker::constraint::colocation { 'nova-api-with-nova-vncproxy-colocation':
    #  source => "${::nova::params::api_service_name}-clone",
    #  target => "${::nova::params::vncproxy_service_name}-clone",
    #  score => "INFINITY",
    #  require => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
    #              Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    #}
    pacemaker::constraint::base { 'nova-api-then-nova-scheduler-constraint':
      constraint_type => "order",
      first_resource  => "${::nova::params::api_service_name}-clone",
      second_resource => "${::nova::params::scheduler_service_name}-clone",
      first_action    => "start",
      second_action   => "start",
      require => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                  Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-scheduler-with-nova-api-colocation':
      source => "${::nova::params::scheduler_service_name}-clone",
      target => "${::nova::params::api_service_name}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                  Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::base { 'nova-scheduler-then-nova-conductor-constraint':
      constraint_type => "order",
      first_resource  => "${::nova::params::scheduler_service_name}-clone",
      second_resource => "${::nova::params::conductor_service_name}-clone",
      first_action    => "start",
      second_action   => "start",
      require => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                  Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-conductor-with-nova-scheduler-colocation':
      source => "${::nova::params::conductor_service_name}-clone",
      target => "${::nova::params::scheduler_service_name}-clone",
      score => "INFINITY",
      require => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                  Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }

    # Ceilometer
    pacemaker::resource::service { $::ceilometer::params::agent_central_service_name :
      clone_params => 'interleave=true',
      require      => [Pacemaker::Resource::Service[$::keystone::params::service_name],
                       $mongodb_pacemaker_resource],
    }
    pacemaker::resource::service { $::ceilometer::params::collector_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::api_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::alarm_evaluator_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::alarm_notifier_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::agent_notification_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::ocf { 'delay' :
      ocf_agent_name  => 'heartbeat:Delay',
      clone_params    => 'interleave=true',
      resource_params => 'startdelay=10',
    }
    pacemaker::constraint::base { 'ceilometer-central-then-ceilometer-collector-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_central_service_name}-clone",
      second_resource => "${::ceilometer::params::collector_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-collector-then-ceilometer-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::collector_service_name}-clone",
      second_resource => "${::ceilometer::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'ceilometer-api-with-ceilometer-collector-colocation':
      source  => "${::ceilometer::params::api_service_name}-clone",
      target  => "${::ceilometer::params::collector_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-api-then-ceilometer-delay-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::api_service_name}-clone",
      second_resource => 'delay-clone',
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                          Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::colocation { 'ceilometer-delay-with-ceilometer-api-colocation':
      source  => 'delay-clone',
      target  => "${::ceilometer::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::base { 'ceilometer-delay-then-ceilometer-alarm-evaluator-constraint':
      constraint_type => 'order',
      first_resource  => 'delay-clone',
      second_resource => "${::ceilometer::params::alarm_evaluator_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::alarm_evaluator_service_name],
                          Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::colocation { 'ceilometer-alarm-evaluator-with-ceilometer-delay-colocation':
      source  => "${::ceilometer::params::alarm_evaluator_service_name}-clone",
      target  => 'delay-clone',
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::base { 'ceilometer-alarm-evaluator-then-ceilometer-alarm-notifier-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::alarm_evaluator_service_name}-clone",
      second_resource => "${::ceilometer::params::alarm_notifier_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::alarm_evaluator_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::alarm_notifier_service_name]],
    }
    pacemaker::constraint::colocation { 'ceilometer-alarm-notifier-with-ceilometer-alarm-evaluator-colocation':
      source  => "${::ceilometer::params::alarm_notifier_service_name}-clone",
      target  => "${::ceilometer::params::alarm_evaluator_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::alarm_evaluator_service_name],
                  Pacemaker::Resource::Service[$::ceilometer::params::alarm_notifier_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-alarm-notifier-then-ceilometer-notification-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::alarm_notifier_service_name}-clone",
      second_resource => "${::ceilometer::params::agent_notification_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::alarm_notifier_service_name]],
    }
    pacemaker::constraint::colocation { 'ceilometer-notification-with-ceilometer-alarm-notifier-colocation':
      source  => "${::ceilometer::params::agent_notification_service_name}-clone",
      target  => "${::ceilometer::params::alarm_notifier_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name],
                  Pacemaker::Resource::Service[$::ceilometer::params::alarm_notifier_service_name]],
    }
    if downcase(hiera('ceilometer_backend')) == 'mongodb' {
      pacemaker::constraint::base { 'mongodb-then-ceilometer-central-constraint':
        constraint_type => 'order',
        first_resource  => "${::mongodb::params::service_name}-clone",
        second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                            Pacemaker::Resource::Service[$::mongodb::params::service_name]],
      }
    }
    pacemaker::constraint::base { 'keystone-then-ceilometer-central-constraint':
      constraint_type => 'order',
      first_resource  => "${::keystone::params::service_name}-clone",
      second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Service[$::keystone::params::service_name]],
    }

    # Heat
    pacemaker::resource::service { $::heat::params::api_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::api_cloudwatch_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::api_cfn_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::engine_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::constraint::base { 'heat-api-then-heat-api-cfn-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_service_name}-clone",
      second_resource => "${::heat::params::api_cfn_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cfn-with-heat-api-colocation':
      source  => "${::heat::params::api_cfn_service_name}-clone",
      target  => "${::heat::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cfn-then-heat-api-cloudwatch-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cfn_service_name}-clone",
      second_resource => "${::heat::params::api_cloudwatch_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cloudwatch-with-heat-api-cfn-colocation':
      source  => "${::heat::params::api_cloudwatch_service_name}-clone",
      target  => "${::heat::params::api_cfn_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cloudwatch-then-heat-engine-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cloudwatch_service_name}-clone",
      second_resource => "${::heat::params::engine_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                  Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-engine-with-heat-api-cloudwatch-colocation':
      source  => "${::heat::params::engine_service_name}-clone",
      target  => "${::heat::params::api_cloudwatch_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                  Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-notification-then-heat-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_notification_service_name}-clone",
      second_resource => "${::heat::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name]],
    }

  }

} #END STEP 4
