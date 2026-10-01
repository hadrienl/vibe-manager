from server import responses, settings

ALLOWED = {"image/png", "image/jpeg", "application/pdf"}


def _too_large(size):
    return size > settings.UPLOAD_LIMIT_MB * 1024 * 1024


def handle_upload(content_type, size):
    if content_type not in ALLOWED:
        return responses.UNSUPPORTED
    if _too_large(size):
        return responses.TOO_LARGE
    return responses.OK
