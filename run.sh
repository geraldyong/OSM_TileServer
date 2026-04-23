#!/bin/bash

set -euo pipefail

function createPostgresConfig() {
  cp /etc/postgresql/$PG_VERSION/main/postgresql.custom.conf.tmpl /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

function buildExternalDataCaBundle() {
    local bundle=/tmp/external-data-ca-bundle.pem
    local host
    local certs

    cp /etc/ssl/certs/ca-certificates.crt "$bundle"

    for host in osmdata.openstreetmap.de naturalearth.s3.amazonaws.com; do
        certs=$(mktemp)

        if openssl s_client -showcerts -servername "$host" -connect "$host:443" </dev/null 2>/dev/null > "$certs"; then
            awk '
                /-----BEGIN CERTIFICATE-----/ { keep=1 }
                keep { print }
                /-----END CERTIFICATE-----/ { keep=0 }
            ' "$certs" >> "$bundle"
        fi

        rm -f "$certs"
    done

    echo "$bundle"
}

function runExternalDataImport() {
    local loader=/data/style/scripts/get-external-data.py
    local config=/data/style/external-data.yml
    local bundle

    if ! [ -f "$loader" ] || ! [ -f "$config" ]; then
        return 0
    fi

    bundle=$(buildExternalDataCaBundle)

    sudo -E -u renderer env \
        REQUESTS_CA_BUNDLE="$bundle" \
        CURL_CA_BUNDLE="$bundle" \
        SSL_CERT_FILE="$bundle" \
        python3 "$loader" -c "$config" -D /data/style/data
}

function ensureFallbackExternalTables() {
    sudo -u postgres psql -d gis <<'SQL'
CREATE TABLE IF NOT EXISTS simplified_water_polygons (way geometry(Geometry,3857));
CREATE TABLE IF NOT EXISTS water_polygons (way geometry(Geometry,3857));
CREATE TABLE IF NOT EXISTS icesheet_polygons (way geometry(Geometry,3857));
CREATE TABLE IF NOT EXISTS icesheet_outlines (way geometry(Geometry,3857), ice_edge text);
CREATE TABLE IF NOT EXISTS ne_110m_admin_0_boundary_lines_land (way geometry(Geometry,3857));

ALTER TABLE simplified_water_polygons OWNER TO renderer;
ALTER TABLE water_polygons OWNER TO renderer;
ALTER TABLE icesheet_polygons OWNER TO renderer;
ALTER TABLE icesheet_outlines OWNER TO renderer;
ALTER TABLE ne_110m_admin_0_boundary_lines_land OWNER TO renderer;

GRANT SELECT ON simplified_water_polygons TO renderer;
GRANT SELECT ON water_polygons TO renderer;
GRANT SELECT ON icesheet_polygons TO renderer;
GRANT SELECT ON icesheet_outlines TO renderer;
GRANT SELECT ON ne_110m_admin_0_boundary_lines_land TO renderer;

INSERT INTO simplified_water_polygons (way)
SELECT ST_GeomFromText('POLYGON EMPTY', 3857)
WHERE NOT EXISTS (SELECT 1 FROM simplified_water_polygons WHERE way IS NOT NULL);

INSERT INTO water_polygons (way)
SELECT ST_GeomFromText('POLYGON EMPTY', 3857)
WHERE NOT EXISTS (SELECT 1 FROM water_polygons WHERE way IS NOT NULL);

INSERT INTO icesheet_polygons (way)
SELECT ST_GeomFromText('POLYGON EMPTY', 3857)
WHERE NOT EXISTS (SELECT 1 FROM icesheet_polygons WHERE way IS NOT NULL);

INSERT INTO icesheet_outlines (way, ice_edge)
SELECT ST_GeomFromText('LINESTRING EMPTY', 3857), NULL
WHERE NOT EXISTS (SELECT 1 FROM icesheet_outlines WHERE way IS NOT NULL);

INSERT INTO ne_110m_admin_0_boundary_lines_land (way)
SELECT ST_GeomFromText('LINESTRING EMPTY', 3857)
WHERE NOT EXISTS (SELECT 1 FROM ne_110m_admin_0_boundary_lines_land WHERE way IS NOT NULL);
SQL
}

if [ "$#" -ne 1 ]; then
    echo "usage: <import|run>"
    echo "commands:"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and renderd to serve tiles at /tile/{z}/{x}/{y}.png"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    NAME_LUA: name of .lua script to run as part of the style"
    echo "    NAME_STYLE: name of the .style to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    exit 1
fi

set -x

# if there is no custom style mounted, then use osm-carto
if [ ! "$(ls -A /data/style/)" ]; then
    mv /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# carto build
if [ ! -f /data/style/mapnik.xml ]; then
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi

if [ "$1" == "import" ]; then
    # Ensure that database directory is in right state
    mkdir -p /data/database/postgres/
    chown renderer: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderer
    sudo -u postgres createdb -E UTF8 -O renderer gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp /data/region.osm.pbf`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown renderer: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore  \
      --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
      --number-processes ${THREADS:-4}  \
      -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
      /data/region.osm.pbf  \
      ${OSM2PGSQL_EXTRA_ARGS:-}  \
    ;

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown renderer: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    # Import external data
    chown -R renderer: /home/renderer/src/ /data/style/
    if ! runExternalDataImport; then
        echo "WARNING: External data download failed; falling back to placeholder tables for any missing low-zoom layers"
    fi
    ensureFallbackExternalTables

    # Register that data has changed for mod_tile caching purposes
    sudo -u renderer touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    # migrate old files
    if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
        mkdir /data/database/postgres/
        mv /data/database/* /data/database/postgres/
    fi
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
    fi
    if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
        mv /data/tiles/data.poly /data/database/region.poly
    fi

    # sync planet-import-complete file
    if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Fix postgres data privileges
    chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

    # Configure Apache CORS
    if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
        echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    fi

    # Initialize PostgreSQL and Apache
    createPostgresConfig
    service postgresql start
    service apache2 restart
    setPostgresPassword

    # Configure renderd threads
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /etc/renderd.conf

    # start cron job to trigger consecutive updates
    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        /etc/init.d/cron start
        sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
        sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
