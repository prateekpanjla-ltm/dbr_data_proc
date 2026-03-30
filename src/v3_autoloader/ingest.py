import urllib.request
import os
from datetime import datetime, timedelta, timezone

VOLUME_PATH = "/Volumes/gharchive_dev/v3_autoloader/raw_files"
BASE_URL = "https://data.gharchive.org"

# Ensure directory exists
os.makedirs(VOLUME_PATH, exist_ok=True)

now_utc = datetime.now(timezone.utc)
prev_hour = now_utc - timedelta(hours=1)
default_date = prev_hour.strftime("%Y-%m-%d")
default_hour = str(prev_hour.hour)

print(f"Current UTC time: {now_utc.strftime('%Y-%m-%d %H:%M:%S')}")
print(f"Default download target: {default_date} hour {default_hour}")

dbutils.widgets.text("date", default_date, "Date (YYYY-MM-DD)")
dbutils.widgets.text("hours", default_hour, "Hours (comma-separated)")

target_date = dbutils.widgets.get("date")
hours = [int(h.strip()) for h in dbutils.widgets.get("hours").split(",")]

print(f"\nDownloading GH Archive for {target_date}, hours: {hours}")

# Download new files to volume (skip existing — Auto Loader tracks processed files via checkpoint)
downloaded_files = []
skipped_files = []

for hour in hours:
    filename = f"{target_date}-{hour}.json.gz"
    url = f"{BASE_URL}/{filename}"
    dest = f"{VOLUME_PATH}/{filename}"

    if os.path.exists(dest):
        print(f"SKIPPED: {filename} (already exists)")
        skipped_files.append(filename)
        continue

    print(f"Downloading: {url}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req) as response:
            data = response.read()
        with open(dest, "wb") as out:
            out.write(data)
        print(f"SUCCESS: {filename} ({len(data):,} bytes)")
        downloaded_files.append(filename)
    except Exception as e:
        print(f"FAILED: {filename} - {e}")

if not downloaded_files and not skipped_files:
    raise RuntimeError(
        f"No files downloaded for {target_date}, hours {hours}. "
        f"GH Archive data may not be available yet."
    )

print(f"\n--- Summary ---")
print(f"Downloaded: {len(downloaded_files)} file(s)")
print(f"Skipped:    {len(skipped_files)} file(s) (already existed)")

print(f"\nFiles in volume:")
for f in sorted(os.listdir(VOLUME_PATH)):
    size = os.path.getsize(f"{VOLUME_PATH}/{f}")
    print(f"  {f} ({size:,} bytes)")