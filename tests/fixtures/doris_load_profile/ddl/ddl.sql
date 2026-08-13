CREATE TABLE insert_probe (
    id BIGINT,
    value VARCHAR(32)
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES ("replication_num"="1");
CREATE TABLE dates_probe (
    d_datekey INT,
    d_date VARCHAR(32),
    d_dayofweek VARCHAR(16),
    d_month VARCHAR(16),
    d_year INT,
    d_yearmonthnum INT,
    d_yearmonth VARCHAR(16),
    d_daynuminweek INT,
    d_daynuminmonth INT,
    d_daynuminyear INT,
    d_monthnuminyear INT,
    d_weeknuminyear INT,
    d_sellingseason VARCHAR(32),
    d_lastdayinweekfl INT,
    d_lastdayinmonthfl INT,
    d_holidayfl INT,
    d_weekdayfl INT,
    d_dummy VARCHAR(8)
)
DUPLICATE KEY(d_datekey)
DISTRIBUTED BY HASH(d_datekey) BUCKETS 1
PROPERTIES ("replication_num"="1");

CREATE TABLE stream_probe (
    id BIGINT,
    value VARCHAR(32)
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES ("replication_num"="1");
