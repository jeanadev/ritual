#!/usr/bin/env python3
"""
fetch-calendar.py
Pulls today's events from Google Calendar (6am–7pm window).
Outputs a formatted markdown block for injection into the morning prompt.

Auth: OAuth 2.0. On first run, opens a browser for authorization.
Token is cached in config/token.json and refreshes automatically.

Setup (one-time):
  1. Create a Google Cloud project at console.cloud.google.com
  2. Enable the Google Calendar API
  3. Create OAuth 2.0 credentials (Desktop app type)
  4. Download as credentials.json → place in config/credentials.json
  5. pip install google-auth-oauthlib google-auth-httplib2 google-api-python-client
"""

import datetime
import os
import sys
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning, module="google")
warnings.filterwarnings("ignore", category=DeprecationWarning, module="urllib3")
import json
from pathlib import Path

# Resolve paths relative to this script's location
SCRIPT_DIR = Path(__file__).parent
ROOT_DIR = SCRIPT_DIR.parent
CONFIG_DIR = ROOT_DIR / "config"
CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"
TOKEN_FILE = CONFIG_DIR / "token.json"

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]

# Load settings
SETTINGS_FILE = CONFIG_DIR / "settings.json"
_settings = json.loads(SETTINGS_FILE.read_text()) if SETTINGS_FILE.exists() else {}
_cal = _settings.get("calendar", {})

DAY_START_HOUR = _cal.get("day_start_hour", 7)
DAY_START_MINUTE = _cal.get("day_start_minute", 30)
DAY_END_HOUR = _cal.get("day_end_hour", 17)
DAY_END_MINUTE = _cal.get("day_end_minute", 30)
BACK_TO_BACK_GAP = _cal.get("back_to_back_gap_minutes", 15)
DEEP_WORK_MIN = _cal.get("deep_work_min_minutes", 60)
LOCAL_TIMEZONE = datetime.datetime.now().astimezone().tzinfo


def local_now():
    return datetime.datetime.now(LOCAL_TIMEZONE)


def local_datetime(day, hour, minute):
    return datetime.datetime.combine(
        day, datetime.time(hour, minute), tzinfo=LOCAL_TIMEZONE
    )


def get_credentials():
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from google.auth.transport.requests import Request

    creds = None

    if TOKEN_FILE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not CREDENTIALS_FILE.exists():
                print(
                    f"ERROR: credentials.json not found at {CREDENTIALS_FILE}\n"
                    "Follow setup instructions in this file's header comment.",
                    file=sys.stderr,
                )
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(
                str(CREDENTIALS_FILE), SCOPES
            )
            creds = flow.run_local_server(port=0)
        TOKEN_FILE.write_text(creds.to_json())

    return creds


def format_event(event):
    """Format a single event as a time-block line."""
    start = event.get("start", {})
    end = event.get("end", {})
    summary = event.get("summary", "(no title)")

    # Skip all-day events (dateTime vs date)
    if "dateTime" not in start:
        return None

    start_dt = datetime.datetime.fromisoformat(start["dateTime"])
    end_dt = datetime.datetime.fromisoformat(end["dateTime"])

    start_str = start_dt.strftime("%-I:%M%p").lower().replace(":00", "")
    end_str = end_dt.strftime("%-I:%M%p").lower().replace(":00", "")

    # Flag back-to-back potential (captured in caller, not here)
    return {
        "start": start_dt,
        "end": end_dt,
        "line": f"{start_str}–{end_str} — {summary}",
    }


def detect_back_to_back(events, gap_minutes=15):
    """Return list of (event_a, event_b) pairs that are back-to-back."""
    pairs = []
    for i in range(len(events) - 1):
        gap = events[i + 1]["start"] - events[i]["end"]
        if gap.total_seconds() / 60 <= gap_minutes:
            pairs.append((events[i], events[i + 1]))
    return pairs


def get_deep_work_windows(events):
    """Find unscheduled blocks >= DEEP_WORK_MIN minutes."""
    windows = []
    day = local_now().date()
    cursor = local_datetime(day, DAY_START_HOUR, DAY_START_MINUTE)

    for event in events:
        gap = event["start"] - cursor
        if gap.total_seconds() / 60 >= DEEP_WORK_MIN:
            windows.append(
                f"{cursor.strftime('%-I:%M%p').lower()}–{event['start'].strftime('%-I:%M%p').lower()}"
            )
        cursor = max(cursor, event["end"])

    end_of_day = local_datetime(day, DAY_END_HOUR, DAY_END_MINUTE)
    gap = end_of_day - cursor
    if gap.total_seconds() / 60 >= DEEP_WORK_MIN:
        windows.append(
            f"{cursor.strftime('%-I:%M%p').lower()}–{end_of_day.strftime('%-I:%M%p').lower()}"
        )

    return windows


def main():
    try:
        from googleapiclient.discovery import build
    except ImportError:
        print(
            "ERROR: Google API client not installed.\n"
            "Run: pip install google-auth-oauthlib google-auth-httplib2 google-api-python-client",
            file=sys.stderr,
        )
        sys.exit(1)

    creds = get_credentials()
    service = build("calendar", "v3", credentials=creds)

    today = local_now().date()
    time_min = local_datetime(today, DAY_START_HOUR, DAY_START_MINUTE).isoformat()
    time_max = local_datetime(today, DAY_END_HOUR, DAY_END_MINUTE).isoformat()

    result = (
        service.events()
        .list(
            calendarId="primary",
            timeMin=time_min,
            timeMax=time_max,
            singleEvents=True,
            orderBy="startTime",
        )
        .execute()
    )

    raw_events = result.get("items", [])
    formatted = [format_event(e) for e in raw_events]
    formatted = [e for e in formatted if e is not None]

    # Build output block
    lines = []
    for e in formatted:
        lines.append(e["line"])

    # Annotations
    bb_pairs = detect_back_to_back(formatted, gap_minutes=BACK_TO_BACK_GAP)
    if bb_pairs:
        lines.append("")
        for a, b in bb_pairs:
            lines.append(
                f"⚠️  Back-to-back: {a['line'].split('—')[0].strip()} → {b['line'].split('—')[0].strip()}"
            )

    deep_windows = get_deep_work_windows(formatted)
    if deep_windows:
        lines.append("")
        lines.append(f"🕐 Deep work window(s): {', '.join(deep_windows)}")
    else:
        lines.append("")
        lines.append("⚠️  No deep work windows found today")

    meeting_count = len(formatted)
    if meeting_count >= 4:
        lines.append(f"⚠️  Meeting-heavy day ({meeting_count} events)")

    print("\n".join(lines))


if __name__ == "__main__":
    main()
