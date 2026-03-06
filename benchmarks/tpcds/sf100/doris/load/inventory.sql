INSERT INTO inventory (inv_date_sk, inv_item_sk, inv_warehouse_sk, inv_quantity_on_hand) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/performance/data/tpcds_sf100/inventory*.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);

