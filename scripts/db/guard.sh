# Shared safety checks for the database scripts (sourced, not run). POSIX sh.
PROD_REF="rfxhqcagdsuhkjzwbawx"   # Classi production project: never a restore or staging target
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }
# Only postgres:// URLs are accepted, and libpq environment overrides are refused: otherwise a key=value string, a
# service file or PGHOST could point somewhere the checks below cannot see.
check_url() {
  case "$1" in postgres://*|postgresql://*) ;; *) echo "refusing: use a postgresql://… connection URL"; exit 2;; esac
  for v in PGHOST PGHOSTADDR PGSERVICE PGSERVICEFILE PGDATABASE PGUSER; do
    eval "x=\${$v:-}"; [ -n "$x" ] && { echo "refusing: unset $v first (it can redirect the connection)"; exit 2; }
  done
  return 0
}
is_prod() { case "$1" in *"$PROD_REF"*) return 0;; *) return 1;; esac; }
# Never print a connection string (it contains the password): only the host (after the last @).
host_of() { echo "$1" | sed -E 's#^[a-z]+://.*@([^:/?]+).*#\1#; s#^[a-z]+://([^:/?@]+).*#\1#'; }
# Row count per table taken from the COPY blocks of a dump: exactly the rows the file holds (same snapshot).
copy_counts() {
  awk '/^COPY /{t=$2; gsub(/"/, "", t); n=0; inb=1; next}
       inb && /^\\\.$/ {print t "|" n; inb=0; next}
       inb {n++}' "$1" | sort
}
