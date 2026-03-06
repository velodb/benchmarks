copy lineitem
from
    's3://${STORAGE_BUCKET}/tpch/sf1000/lineitem/' iam_role default GZIP DELIMITER '|'  REGION 'us-east-1';
