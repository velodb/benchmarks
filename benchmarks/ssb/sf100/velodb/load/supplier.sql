INSERT INTO supplier (
    s_suppkey,s_name,s_address,s_city,s_nation,s_region,s_phone
)
SELECT * FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "s_suppkey:int;s_name:string;s_address:string;s_city:string;s_nation:string;s_region:string;s_phone:string",
        "compress_type"="gz"
);
