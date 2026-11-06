#!/usr/bin/env bash
# Prepare only the independent Watch5 backend. Does not touch the metalcarcase production site.
set -euo pipefail
umask 077

APP_ROOT="${HOME}/watch5-voice-capture"
AUDIO_ROOT="${HOME}/watch5-audio-private"
ENV_FILE="${HOME}/.watch5-voice-capture.env"

command -v git >/dev/null || { echo "git is missing" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is missing" >&2; exit 1; }

if [ -d "${APP_ROOT}/.git" ]; then
  echo "Existing repository found. Not updating it automatically."
elif [ -e "${APP_ROOT}" ]; then
  echo "${APP_ROOT} already exists but is not a Git repository. Stop to avoid overwriting." >&2
  exit 1
else
  git clone https://github.com/InternetUzer/watch5-voice-capture.git "${APP_ROOT}"
fi

python3 -m venv "${APP_ROOT}/server/.venv"
"${APP_ROOT}/server/.venv/bin/python" -m pip install -r "${APP_ROOT}/server/requirements.txt"

mkdir -p "${AUDIO_ROOT}"
chmod 700 "${AUDIO_ROOT}"
if [ -f "${ENV_FILE}" ]; then
  echo "Existing ${ENV_FILE} preserved, no secrets modified."
else
  DEVICE_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  echo "Enter Yandex OAuth token (hidden while typing), or press Enter to configure later:"
  read -r -s YANDEX_SECRET
  printf '\n'
  {
    printf 'WATCH_API_KEY=%s\n' "${DEVICE_KEY}"
    printf 'YANDEX_DISK_TOKEN=%s\n' "${YANDEX_SECRET}"
    printf 'YANDEX_DISK_FOLDER=disk:/Watch5-Voice-Capture\n'
    printf 'WATCH_STORAGE_DIR=%s\n' "${AUDIO_ROOT}"
    printf 'WATCH_APP_ROOT=%s\n' "${APP_ROOT}/server"
  } > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  echo "Device API key stored only in ${ENV_FILE}. Read it on the server when configuring the watch."
fi

cd "${APP_ROOT}/server"
.venv/bin/python -m pytest -q

echo "Prepared independent service under ${APP_ROOT}."
echo "Next: create a separate HTTPS Python site voice.metalcarcase.ru in ISPmanager,"
echo "and use server/passenger_wsgi.py as its Passenger entrypoint."
