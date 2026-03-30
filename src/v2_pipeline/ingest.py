
import urllib.request
import os
from datetime import datetime, timedelta, timezone

VOLUME_PATH = "/Volumes/gharchive_dev/v2_pipeline/files"
LATEST_DIR = f"{VOLUME_PATH}/latest"
ARCHIVE_DIR = f"{VOLUME_PATH}/archive"
BASE_URL = "https://data.gharchive.org"

# Ensure directories exist
os.makedirs(LATEST_DIR, exist_ok=True)
os.makedirs(ARCHIVE_DIR, exist_ok=True)

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

# Step 1: Move existing files from latest/ to archive/
try:
    existing = dbutils.fs.ls(LATEST_DIR)
    for f in existing:
        dest = f"{ARCHIVE_DIR}/{f.name}"
        dbutils.fs.mv(f.path, dest)
        print(f"ARCHIVED: {f.name}")
except Exception:
    print("No existing files in latest/ to archive")

# Step 2: Download new files to latest/
downloaded_files = []
for hour in hours:
    filename = f"{target_date}-{hour}.json.gz"
    url = f"{BASE_URL}/{filename}"
    dest = f"{LATEST_DIR}/{filename}"

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

if not downloaded_files:
    raise RuntimeError(f"No files downloaded for {target_date}, hours {hours}. GH Archive data may not be available yet.")

print(f"\nDownloaded {len(downloaded_files)} file(s) to latest/")
print("\nFiles in latest/:")
for f in dbutils.fs.ls(LATEST_DIR):
    print(f"  {f.name} ({f.size:,} bytes)")