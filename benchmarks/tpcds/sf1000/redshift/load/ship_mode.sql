copy ship_mode
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/ship_mode/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';