LOAD LABEL inventory_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf1000/inventory/inventory*.*")
    INTO TABLE inventory
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (inv_date_sk, inv_item_sk, inv_warehouse_sk, inv_quantity_on_hand)
)
WITH S3
(
    "AWS_ENDPOINT" = "${STORAGE_ENDPOINT}",
    "AWS_REGION" = "${STORAGE_REGION}",
    "use_path_style" = "false"
)
PROPERTIES
(
    "timeout" = "36000",
    "load_parallelism" = "8",
    "max_filter_ratio" = "0.1"
);
