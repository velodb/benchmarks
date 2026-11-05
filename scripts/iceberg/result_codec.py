import hashlib,json,decimal,datetime,base64

def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_value(value):
    if isinstance(value, decimal.Decimal):
        return {'decimal': str(value)}
    if isinstance(value, (datetime.date, datetime.datetime, datetime.time)):
        return {type(value).__name__: value.isoformat()}
    if isinstance(value, bytes):
        return {'bytes_base64': base64.b64encode(value).decode()}
    if isinstance(value, datetime.timedelta):
        return {'timedelta_seconds': value.total_seconds()}
    raise TypeError(type(value).__name__)


def canonical(value):
    if value is None:
        return ['null']
    if isinstance(value, (int, float, decimal.Decimal)):
        number = decimal.Decimal(str(value))
        if not number.is_finite():
            return ['nonfinite_number', str(number)]
        if number == 0:
            return ['number', '0']
        with decimal.localcontext() as context:
            context.prec = max(100, len(number.as_tuple().digits))
            return ['number', format(number.normalize(), 'f')]
    if isinstance(value, str):
        return ['string', value]
    if isinstance(value, bytes):
        return ['bytes', base64.b64encode(value).decode()]
    return [type(value).__name__, json_value(value)]


def fingerprints(rows, column_count):
    encoded = [json.dumps([canonical(x) for x in row], ensure_ascii=False,
                          separators=(',', ':')) for row in rows]
    prefix = str(column_count) + '\n'
    return {'row_count': len(rows), 'column_count': column_count,
            'ordered_sha256': sha((prefix + '\n'.join(encoded)).encode()),
            'multiset_sha256': sha((prefix + '\n'.join(sorted(encoded))).encode())}
