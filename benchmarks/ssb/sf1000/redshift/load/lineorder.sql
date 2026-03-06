copy lineorder
from
    's3://${STORAGE_BUCKET}/ssb/sf1000/lineorder/' iam_role default GZIP DELIMITER '|'  REGION 'us-east-1';