Add a new 1:1 person to the ritual project.

1. Ask the user for:
   - The exact calendar event title (as it appears in Google Calendar)
   - The short name for the person (e.g. "alex") — this becomes the filename and display name

2. Add the entry to `config/oneone-map.zsh` inside the existing `ONEONE_MAP` declaration:
   ```
   ["Exact Calendar Title"]="shortname"
   ```

3. Create `notes/1on1/<shortname>.md` if it doesn't exist yet (empty file is fine).

4. Confirm what was added and remind the user that the calendar title must match exactly (case-sensitive).
