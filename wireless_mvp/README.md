# wireless_mvp

Wireless OCR translator: Flutter Web frontend + FastAPI backend (reusing the
existing Google Vision / Translation / OpenCV pipeline) + an ESP32-S3 camera
(Freenove, PlatformIO firmware under `firmware/`).

## Run the backend

From `wireless_mvp/`:

```powershell
python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
```

`--host 0.0.0.0` is required so the ESP32 and the Flutter app (if opened from
another device) can reach it over the LAN. `--host 127.0.0.1` (uvicorn's
default) is not reachable from anywhere except this machine.

Requires the packages in `wireless_mvp/requirements.txt` and Google Cloud
credentials available via Application Default Credentials
(`GOOGLE_APPLICATION_CREDENTIALS`) or the `gcloud` CLI fallback used by
`OCR/google_vision.py` / `translation/translator.py`.

## Run the frontend

```powershell
cd frontend
flutter pub get
flutter run -d chrome
```

In the app's Settings dialog (gear icon), set:

- **Backend URL**: this machine's LAN IP and port, e.g. `http://10.0.0.90:8000`
  (never `localhost` — the ESP32 can't resolve that back to this machine).
- **ESP32 camera URL**: the ESP32's IP or mDNS name, e.g. `http://esp32cam.local`
  or `http://192.168.1.60`.

## Ports

| Port | Used by |
|------|---------|
| 8000 | FastAPI backend (`/api/languages`, `/api/process`, `/api/v1/jobs`, ...) |
| 80   | ESP32 HTTP control server (`/capture`, `/upload_job`, `/button_event`) |
| 81   | ESP32 MJPEG live-view stream (`/stream`), consumed directly by Flutter |

## Firmware

PlatformIO project under `firmware/` (`platformio.ini`, `src/`, `include/`,
`partitions.csv`). Build/upload:

```powershell
cd firmware
& C:\Users\<you>\.platformio\penv\Scripts\platformio.exe run --target upload
```

`firmware/src/main.cpp` currently has the WiFi SSID/password hardcoded for
testing. Treat that file as containing a local secret before sharing it.
