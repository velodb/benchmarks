LOAD LABEL customer_address_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf100/customer_address/customer_address*.*")
    INTO TABLE customer_address
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (ca_address_sk, ca_address_id, ca_street_number, ca_street_name, ca_street_type, ca_suite_number, ca_city, ca_county, ca_state, ca_zip, ca_country, ca_gmt_offset, ca_location_type)
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
