import os

# Megabytes; the deployment may raise it.
UPLOAD_LIMIT_MB = int(os.environ.get("UPLOAD_LIMIT_MB", "25"))
