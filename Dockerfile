FROM overv/openstreetmap-tile-server

COPY leaflet-demo.html /var/www/html/index.html
COPY run.sh /

ENTRYPOINT ["/run.sh"]
CMD []
