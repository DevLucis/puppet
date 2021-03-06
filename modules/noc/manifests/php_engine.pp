# === Class noc::php_engine
# Configures apache to serve requests via HHVM/any other FastCGI backend
class noc::php_engine($catchall_ensure=present) {
    include ::apache::mod::proxy_fcgi

    apache::mod_conf { 'mod_php5':
        ensure => absent,
    }

    # HHVM catchall, and removal of mod_php
    apache::conf { 'hhvm_catchall':
        ensure   => $catchall_ensure,
        source   => 'puppet:///modules/mediawiki/apache/configs/hhvm_catchall.conf',
        priority => 50,
    }

    # Add headers lost by mod_proxy_fastcgi
    apache::conf { 'fcgi_headers':
        source   => 'puppet:///modules/mediawiki/apache/configs/fcgi_headers.conf',
        priority => 0,
    }
}
