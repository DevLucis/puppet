# == Class: role::eventlogging
#
# This role configures an instance to act as the primary EventLogging
# log processor for the cluster. The setup is described in detail on
# <https://wikitech.wikimedia.org/wiki/EventLogging>. End-user
# documentation is available in the form of a guide, located at
# <https://www.mediawiki.org/wiki/Extension:EventLogging/Guide>.
#
# There exist two APIs for generating events: efLogServerSideEvent() in
# PHP and mw.eventLog.logEvent() in JavaScript. Events generated in PHP
# are sent by the app servers directly to eventlog* servers on UDP port 8421.
# JavaScript-generated events are URL-encoded and sent to our servers by
# means of an HTTP/S request to bits, which a varnishncsa instance
# forwards to eventlog* on port 8422. These event streams are parsed,
# validated, and multiplexed into an output stream that is published via
# ZeroMQ on TCP port 8600. Data sinks are implemented as subscribers
# that connect to this endpoint and read data into some storage medium.
#
class role::eventlogging {
    class { '::eventlogging': }

    # Infer Kafka cluster configuration from this class
    class { 'role::analytics::kafka::config': }

    if hiera('has_ganglia', true) {
        class { 'role::eventlogging::monitoring': }
    }

    system::role { 'role::eventlogging':
        description => 'EventLogging',
    }

    # Event data flows through several processes that communicate with each
    # other via TCP/IP sockets. By default, all processing is performed
    # on one node, but the work could be easily distributed across multiple hosts.
    $processor = '0.0.0.0'

    ## Data flow

    # Server-side events are generated by MediaWiki and sent to eventlog*
    # on UDP port 8421, using wfErrorLog('...', 'udp://...'). eventlog*
    # is specified as the destination in $wgEventLoggingFile, declared
    # in wmf-config/CommonSettings.php.
    eventlogging::service::forwarder { 'server-side-raw':
        input   => 'udp://0.0.0.0:8421',
        outputs => ["tcp://${processor}:8421"],
    }
    eventlogging::service::processor { 'server-side events':
        format => '%{seqId}d EventLogging %j',
        input  => "tcp://${processor}:8421",
        output => "tcp://${processor}:8521",
    }

    # Client-side events are generated by JavaScript-triggered HTTP/S
    # requests to //bits.wikimedia.org/event.gif?<event payload>.
    # A varnishncsa instance on the bits caches greps for these requests
    # and forwards them to eventlog* on UDP port 8422. The varnishncsa
    # configuration is specified in <manifests/role/cache.pp>.
    eventlogging::service::forwarder { 'client-side-raw':
        input => 'udp://0.0.0.0:8422',
        outputs => ["tcp://${processor}:8422"],
    }
    eventlogging::service::processor { 'client-side events':
        format => '%q %{recvFrom}s %{seqId}d %t %h %{userAgent}i',
        input  => "tcp://${processor}:8422",
        output => "tcp://${processor}:8522",
    }

    # Parsed and validated client-side (varnishncsa generated) and
    # server-side (MediaWiki-generated) events are multiplexed into a
    # single output stream, published on TCP port 8600.
    eventlogging::service::multiplexer { 'all events':
        inputs => [ "tcp://${processor}:8521", "tcp://${processor}:8522" ],
        output => "tcp://${processor}:8600",
    }


    ## MySQL / MariaDB

    # Log strictly valid events to the 'log' database on m4-master.

    class { 'passwords::mysql::eventlogging': }    # T82265
    $mysql_user = $passwords::mysql::eventlogging::user
    $mysql_pass = $passwords::mysql::eventlogging::password
    $mysql_db = $::realm ? {
        production => 'm4-master.eqiad.wmnet/log',
        labs       => '127.0.0.1/log',
    }

    eventlogging::service::consumer { 'mysql-m4-master':
        input  => "tcp://${processor}:8600",
        output => "mysql://${mysql_user}:${mysql_pass}@${mysql_db}?charset=utf8",
        # Restrict permissions on this config file since it contains a password.
        owner  => 'root',
        group  => 'eventlogging',
        mode   => '0640',
    }


    ## Flat files

    # Log all raw log records and decoded events to flat files in
    # $log_dir as a medium of last resort. These files are rotated
    # and rsynced to stat1003 & stat1002 for backup.

    $log_dir = $::eventlogging::log_dir

    eventlogging::service::consumer {
        'server-side-events.log':
            input  => "tcp://${processor}:8421?raw=1",
            output => "file://${log_dir}/server-side-events.log";
        'client-side-events.log':
            input  => "tcp://${processor}:8422?raw=1",
            output => "file://${log_dir}/client-side-events.log";
        'all-events.log':
            input  => "tcp://${processor}:8600",
            output => "file://${log_dir}/all-events.log";
    }

    $backup_destinations = $::realm ? {
        production => [  'stat1002.eqiad.wmnet', 'stat1003.eqiad.wmnet' ],
        labs       => false,
    }

    if ( $backup_destinations ) {
        class { 'rsync::server': }

        rsync::server::module { 'eventlogging':
            path        => $log_dir,
            read_only   => 'yes',
            list        => 'yes',
            require     => File[$log_dir],
            hosts_allow => $backup_destinations,
        }
    }

    # jq is very useful, install it on eventlogging servers
    ensure_packages(['jq'])
}


# == Class: role::eventlogging::monitoring
#
# Provisions scripts for reporting state to monitoring tools.
#
class role::eventlogging::monitoring {
    class { '::eventlogging::monitoring': }

    eventlogging::service::reporter { 'statsd':
        host => 'statsd.eqiad.wmnet',
    }

    nrpe::monitor_service { 'eventlogging':
        ensure        => 'present',
        description   => 'Check status of defined EventLogging jobs',
        nrpe_command  => '/usr/lib/nagios/plugins/check_eventlogging_jobs',
        require       => File['/usr/lib/nagios/plugins/check_eventlogging_jobs'],
        contact_group => 'admins,analytics',
    }

    # Alert when / gets low. (eventlog1001 has a 9.1G /)
    nrpe::monitor_service { 'eventlogging_root_disk_space':
        description   => 'Eventlogging / disk space',
        nrpe_command  => '/usr/lib/nagios/plugins/check_disk -w 1024M -c 512M -p /',
        contact_group => 'analytics',
    }

    # Alert when /srv gets low. (eventlog1001 has a 456G /srv)
    # Currently, /srv/log/eventlogging grows at about 500kB / s.
    # Which is almost 2G / hour.  100G gives us about 2 days to respond,
    # 50G gives us about 1 day.  Logrotate should keep enough disk space free.
    nrpe::monitor_service { 'eventlogging_srv_disk_space':
        description   => 'Eventlogging /srv disk space',
        nrpe_command  => '/usr/lib/nagios/plugins/check_disk -w 100000M -c 50000M -p /srv',
        contact_group => 'analytics',
    }
}


# == Class: role::eventlogging::graphite
#
# Keeps a running count of incoming events by schema in Graphite by
# emitting 'eventlogging.SCHEMA_REVISION:1' on each event to a StatsD
# instance.

# The consumer connects to the host in 'input' and outputs data to the
# host in 'output'. The output host should normally be statsd
#
# Includes process nanny alarm for graphite consumer

class role::eventlogging::graphite {
    class { '::eventlogging::monitoring': }

    # Too bad this isn't in a hiera variable :(
    $eventlogging_host = 'eventlog1001.eqiad.wmnet'
    eventlogging::service::consumer { 'graphite':
        input  => "tcp://${eventlogging_host}:8600",
        output => 'statsd://statsd.eqiad.wmnet:8125',
    }

    # Generate icinga alert if the graphite consumer is not running.
    nrpe::monitor_service { 'eventlogging':
        ensure        => 'present',
        description   => 'Check status of defined EventLogging jobs on graphite consumer',
        nrpe_command  => '/usr/lib/nagios/plugins/check_eventlogging_jobs',
        require       => File['/usr/lib/nagios/plugins/check_eventlogging_jobs'],
        contact_group => 'admins,analytics',
    }

}


# Temporary class to test eventlogging kafka on host other than eventlog1001.
class role::eventlogging::processor::kafka {
    class { '::eventlogging': }

    # Infer Kafka cluster configuration from this class
    class { 'role::analytics::kafka::config': }

    $forwarder_host       = hiera('eventlogging_forwarder_host', 'eventlog1001.eqiad.wmnet')
    $kafka_brokers_array  = $role::analytics::kafka::config::brokers_array
    # By default, the EL Kafka writer writes events to
    # schema based topic names like eventlogging_SCHEMA,
    # with each message keyed by SCHEMA_REVISION.
    $kafka_ouput_uri      = inline_template('kafka:///<%= @kafka_brokers_array.join(":9092,") + ":9092" %>')

    # Read in server side and client side raw events from
    # ZeroMQ, process them, and send events to schema
    # based topics in Kafka.
    eventlogging::service::processor { 'server-side-events-kafka':
        format => '%{seqId}d EventLogging %j',
        input  => "tcp://${forwarder_host}:8421",
        output => $kafka_ouput_uri,
    }
    eventlogging::service::processor { 'client-side-events-kafka':
        format => '%q %{recvFrom}s %{seqId}d %t %h %{userAgent}i',
        input  => "tcp://${forwarder_host}:8422",
        output => $kafka_ouput_uri,
    }
}