"""The fingerprint query of scripts/production/fingerprint.sql as ONE SQL expression (part|n|fp lines sorted by part),
shared by the production generators so that the guards and the read-only check can never drift apart."""
import os

_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fingerprint.sql")).read()
_body = _src[_src.index("with f as"):_src.rindex("order by 1;")].strip()
FP = f"(select string_agg(part || '|' || n || '|' || fp, E'\\n' order by part collate \"C\") from ({_body}) s)"
