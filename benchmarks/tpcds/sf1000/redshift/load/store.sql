copy store
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/store/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';