copy item
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/item/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';