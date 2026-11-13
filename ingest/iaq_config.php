<?php
// Settings for iaq_ingest.php. Install as /etc/iaq/config.php, outside the web root:
//   sudo mkdir -p /etc/iaq
//   sudo cp iaq_config.php /etc/iaq/config.php
//   sudo chown root:www-data /etc/iaq/config.php
//   sudo chmod 640 /etc/iaq/config.php

// Database account created by iaq_schema.sql. The password must match the
// one set for 'iaq_ingest' there.
const IAQ_DB_HOST = 'localhost';
const IAQ_DB_USER = 'iaq_ingest';
const IAQ_DB_PASS = 'CHANGE_ME_INGEST';
const IAQ_DB_NAME = 'buildingData';

// Readings are accepted only from addresses starting with this prefix
// (the UX's station network). Set to '' to disable the check.
const IAQ_STATION_PREFIX = '192.168.10.';

// The UX's own address on the station network, refused in case traffic
// port-forwarded from the host network arrives with this source address.
const IAQ_GATEWAY_IP = '192.168.10.1';
