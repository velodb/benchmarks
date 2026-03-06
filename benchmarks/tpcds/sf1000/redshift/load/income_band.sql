copy income_band
from
    's3://${STORAGE_BUCKET}/tpcds/sf1000/income_band/' iam_role default GZIP DELIMITER '|' EMPTYASNULL REGION 'us-east-1';