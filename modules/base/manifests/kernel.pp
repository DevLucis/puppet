# == Class: base::kernel
#
# Settings related to the Linux kernel (currently only blacklisting
# risky kernel modules and adding /etc/modules-load.d/ on Trusty)
#
# [*overlayfs*]
#  bool for whether overlay module is needed

class base::kernel(
    $overlayfs,
    ) {
    if os_version('ubuntu == trusty') {
        # This directory is shipped by systemd, but trusty's upstart job for
        # kmod also parses /etc/modules-load.d/ (but doesn't create the
        # directory).
        file { '/etc/modules-load.d/':
            ensure => 'directory',
            owner  => 'root',
            group  => 'root',
            mode   => '0755',
        }
    }

    if ! $overlayfs {
        kmod::blacklist { 'wmf_overlay':
            modules => [
                'overlayfs',
                'overlay',
            ],
        }
    } else {
        kmod::blacklist { 'wmf_overlay':
            ensure => absent,
        }
    }

    kmod::blacklist { 'wmf':
        modules => [
            'aufs',
            'usbip-core',
            'usbip-host',
            'vhci-hcd',
            'dccp',
            'dccp_ipv6',
            'dccp_ipv4',
            'dccp_probe',
            'dccp_diag',
            'n_hdlc',
            'intel_cstate',
            'intel_rapl_perf',
            'intel_uncore',
            'parport',
            'parport_pc',
            'ppdev',
            'acpi_power_meter',
            'bluetooth',
            'v4l2-common',
            'floppy',
            'cdrom',
        ],
    }

    if (versioncmp($::kernelversion, '4.4') >= 0) {
        kmod::blacklist { 'linux44':
            modules => [ 'asn1_decoder', 'macsec' ],
        }
    }

    # This section is for blacklisting modules per server model.
    # It was originally started for acpi_pad issues on R320 (T162850)
    # but is meant to be extended as needed.
    case $::productname {
      'PowerEdge R320': {
        kmod::blacklist { 'r320':
            modules => [ 'acpi_pad' ],
        }
      }
      default: {}
    }

    # Settings to mitigate fragmentsmack. The low settings need to be applied
    # before the high settings, otherwise the new high settings are lower than
    # the current kernel defaults which results in sysctl rejecting the value
    # The latest kernel update for stretch also pushes these settings by default
    # in the kernel, so at some point this can be removed in puppet
    sysctl::parameters { 'ipfrag_low':
        values   => {
            'net.ipv4.ipfrag_low_thresh'  => '196608',
            'net.ipv6.ip6frag_low_thresh' => '196608',
        },
        priority => 10,
        before   => Sysctl::Parameters['ipfrag_high']
    }

    sysctl::parameters { 'ipfrag_high':
        values   => {
            'net.ipv4.ipfrag_high_thresh'  => '262144',
            'net.ipv6.ip6frag_high_thresh' => '262144',
        },
        priority => 11,
    }

    # By default trusty allows the creation of user namespaces by unprivileged users
    # (Debian defaulted to disallowing these since the feature was introduced for security reasons)
    # Unprivileged user namespaces are not something we need in general (and especially
    # not in trusty where support for namespaces is incomplete) and was the source for
    # several local privilege escalation vulnerabilities. Fortunately the 3.13.0-91 release
    # introduced a backport of the Debian patch allowing to disable the creation of user
    # namespaces via a sysctl. There's a few servers we haven't been able to migrate to
    # that kernel for technical reasons, so make the creation of the sysctl dependant on
    # the kernel release.
    if os_version('ubuntu == trusty') and (versioncmp($::kernelrelease, '3.13.0-91') >= 0) {
        sysctl::parameters { 'disable-unprivileged-user-namespaces':
            values => {
                'kernel.unprivileged_userns_clone' => 0,
            },
        }
    }
}
