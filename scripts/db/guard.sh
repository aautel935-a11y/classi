# Shared safety checks for the database scripts (sourced, not run).
PROD_REF="rfxhqcagdsuhkjzwbawx"   # Classi production project: never written to by these scripts
is_prod() { case "$1" in *"$PROD_REF"*) return 0;; *) return 1;; esac; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }
# Never print a connection string (it contains the password): show only the host.
host_of() { echo "$1" | sed -E 's#^[a-z]+://[^@]*@([^:/?]+).*#\1#'; }
