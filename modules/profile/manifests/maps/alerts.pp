# Define various checks for Maps
class profile::maps::alerts {
    monitoring::graphite_threshold { 'tilerator-tile-generation':
        description     => 'Maps tiles generation',
        dashboard_links => ['https://grafana.wikimedia.org/dashboard/db/maps-performances?panelId=8&fullscreen&orgId=1'],
        metric          => 'transformNull(sumSeries(tilerator.gen.*.*.*.done.sample_rate),0)',
        # Tilerator should be generating tiles at least 2 hours per day
        # Values need to be adjusted if synchronization frequency is changed
        under           => true,
        warning         => 10,
        critical        => 5,
        from            => '1day',
        percentage      => 90,
    }

    # Temporarily restrict this check to only maps1001, untill data is fully imported on maps1004 (T205462)
    monitoring::check_prometheus { 'maps-osm-sync-lag-eqiad':
      description     => 'Maps - OSM synchronization lag - eqiad',
      dashboard_links => ['https://grafana.wikimedia.org/dashboard/db/maps-performances?panelId=11&fullscreen&orgId=1'],
      query           => 'scalar(max(time()-osm_sync_timestamp{cluster="maps", instance="maps1001:9100"}))',
      warning         => 25 * 3600, # 25 hours
      critical        => 48 * 3600, # 48 hours
      prometheus_url  => 'http://prometheus.svc.eqiad.wmnet/ops',
    }
    monitoring::check_prometheus { 'maps-osm-sync-lag-codf':
        description     => 'Maps - OSM synchronization lag - codfw',
        dashboard_links => ['https://grafana.wikimedia.org/dashboard/db/maps-performances?panelId=12&fullscreen&orgId=1'],
        query           => 'scalar(max(time()-osm_sync_timestamp{cluster="maps"}))',
        warning         => 25 * 3600, # 25 hours
        critical        => 48 * 3600, # 48 hours
        prometheus_url  => 'http://prometheus.svc.codfw.wmnet/ops',
    }
}
