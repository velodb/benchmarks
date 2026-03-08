INSERT INTO time_dim (t_time_sk, t_time_id, t_time, t_hour, t_minute, t_second, t_am_pm, t_shift, t_sub_shift, t_meal_time) SELECT * FROM S3 (
    "uri" = "s3://${STORAGE_BUCKET}/tpcds/sf1000/time_dim/time_dim*.*",
    "format" = "csv",
    "s3.endpoint" = "${STORAGE_ENDPOINT}",
    "s3.region" = "${STORAGE_REGION}",
    "column_separator" = "|"
);


