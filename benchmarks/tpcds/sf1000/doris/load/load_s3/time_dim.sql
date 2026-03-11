LOAD LABEL time_dim_${TIMESTAMP}
(
    DATA INFILE("s3://${STORAGE_BUCKET}/tpcds/sf1000/time_dim/time_dim*.*")
    INTO TABLE time_dim
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (t_time_sk, t_time_id, t_time, t_hour, t_minute, t_second, t_am_pm, t_shift, t_sub_shift, t_meal_time)
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
