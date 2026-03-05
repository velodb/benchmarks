INSERT INTO supplier (s_suppkey,s_name,s_address,s_city,s_nation,s_region,s_phone) SELECT c1, c2, c3, c4, c5, c6, c7 FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/ssb/sf1000/supplier/*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|",
    "skip_lines" = "0"
);