LOAD LABEL dates_profile_integration_${TIMESTAMP}
(
    DATA INFILE("s3://bench-dataset/ssb/sf100/date/date.tbl.gz")
    INTO TABLE dates_probe
    COLUMNS TERMINATED BY "|"
    FORMAT AS "csv"
    (
        d_datekey,d_date,d_dayofweek,d_month,d_year,d_yearmonthnum,
        d_yearmonth,d_daynuminweek,d_daynuminmonth,d_daynuminyear,
        d_monthnuminyear,d_weeknuminyear,d_sellingseason,
        d_lastdayinweekfl,d_lastdayinmonthfl,d_holidayfl,d_weekdayfl,d_dummy
    )
)
WITH S3
(
    "AWS_ENDPOINT"="https://s3.us-east-1.amazonaws.com",
    "AWS_REGION"="us-east-1",
    "use_path_style"="false"
)
PROPERTIES
(
    "timeout"="300",
    "max_filter_ratio"="0.1"
);
