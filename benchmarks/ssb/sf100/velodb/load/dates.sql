INSERT INTO dates (
    d_datekey,d_date,d_dayofweek,d_month,d_year,d_yearmonthnum,d_yearmonth,d_daynuminweek,d_daynuminmonth,d_daynuminyear,d_monthnuminyear,d_weeknuminyear,d_sellingseason,d_lastdayinweekfl,d_lastdayinmonthfl,d_holidayfl,d_weekdayfl
) SELECT * FROM S3 (
        "uri" = "s3://${STORAGE_BUCKET}/ssb/sf100/date/*",
        "format" = "csv",
        "s3.endpoint" = "${STORAGE_ENDPOINT}",
        "s3.region" = "${STORAGE_REGION}",
        "column_separator" = "|",
        csv_schema = "d_datekey:int;d_date:string;d_dayofweek:string;d_month:string;d_year:int;d_yearmonthnum:int;d_yearmonth:string;d_daynuminweek:int;d_daynuminmonth:int;d_daynuminyear:int;d_monthnuminyear:int;d_weeknuminyear:int;d_sellingseason:string;d_lastdayinweekfl:int;d_lastdayinmonthfl:int;d_holidayfl:int;d_weekdayfl:int",
        "compress_type"="gz"
);