DROP CATALOG IF EXISTS iceberg_nessie;

CREATE CATALOG `iceberg_nessie` PROPERTIES (
    "warehouse" = "warehouse",
    "uri" = "http://172.20.48.9:19120/iceberg",
    "type" = "iceberg",
    "s3.secret_key" = "*XXX",
    "s3.region" = "${STORAGE_REGION}",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.access_key" = "*XXX",
    "iceberg.catalog.type" = "rest"
);