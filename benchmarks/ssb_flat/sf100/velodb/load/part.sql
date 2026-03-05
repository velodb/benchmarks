INSERT INTO part (
    p_partkey,p_name,p_mfgr,p_category,p_brand,p_color,p_type,p_size,p_container
)
SELECT * FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "p_partkey:int;p_name:string;p_mfgr:string;p_category:string;p_brand:string;p_color:string;p_type:string;p_size:int;p_container:string",
        "compress_type"="gz"
);