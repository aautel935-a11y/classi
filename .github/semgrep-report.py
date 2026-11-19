"""Turn Semgrep JSON into GitHub annotations. Fails (exit 1) on any ERROR-severity finding or on a scan error.
WARNING/INFO findings are annotated as warnings and do not fail the job."""
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception as e:  # semgrep did not produce a report (install or rule download failed)
    print(f"::error::semgrep produced no report: {e}")
    if len(sys.argv) > 2:  # its own error output, last lines, one annotation each
        try:
            for line in [l.strip() for l in open(sys.argv[2], errors="replace") if l.strip()][-15:]:
                print(f"::error::semgrep: {line[:300]}")
        except OSError:
            pass
    sys.exit(1)
errors = 0
for r in data.get("results", []):
    sev = r.get("extra", {}).get("severity", "INFO")
    msg = " ".join(str(r.get("extra", {}).get("message", "")).split())[:300]
    level = "error" if sev == "ERROR" else "warning"
    errors += sev == "ERROR"
    print(f"::{level} file={r['path']},line={r['start']['line']},title={r['check_id']}::{sev}: {msg}")
for e in data.get("errors", []):
    level = e.get("level", "error")
    msg = " ".join(str(e.get("message", e.get("type", ""))).split())[:300]
    print(f"::{'error' if level == 'error' else 'warning'}::semgrep {level}: {msg}")
    errors += level == "error"
n = len(data.get("results", []))
print(f"semgrep: {n} findings, {errors} blocking (ERROR findings or scan errors)")
sys.exit(1 if errors else 0)
