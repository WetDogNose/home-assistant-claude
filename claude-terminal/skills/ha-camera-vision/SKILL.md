---
name: ha-camera-vision
description: Capture a still frame from any Home Assistant camera with ha-snapshot and then actually look at it, so questions about what is physically happening around the house can be answered from the image rather than from sensor states. Use this whenever the user asks what a camera can see, whether the car/bins/parcel/dog is there, whether a door or gate is open, what triggered a motion alert, or asks you to check, look at, or describe anything visible outdoors or in a room. Also use it when a sensor reading is disputed and a camera covers the same spot. After capturing, read the image file so you can describe it — capturing without looking answers nothing.
---

# Looking through Home Assistant's cameras

`ha-snapshot` pulls a current frame from any camera entity via Home Assistant's
camera proxy. Combined with reading the resulting file, it turns "is the gate
open?" into something answerable rather than inferred.

## Capturing

```bash
ha-snapshot <camera_entity_id> [output_file]
```

```bash
ha-snapshot camera.front_door                      # -> /config/www/snapshots/front_door.jpg
ha-snapshot front_door                             # `camera.` prefix added for you
ha-snapshot camera.garage /config/snapshots/garage.jpg
```

It creates the output directory, reports the saved path and size, and on a
non-200 response deletes the empty file and exits 1 rather than leaving a
zero-byte JPEG that looks like a successful capture.

Find the cameras first when the user names a place rather than an entity:

```bash
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states \
  | jq -r '.[] | select(.entity_id | startswith("camera.")) | "\(.entity_id)\t\(.attributes.friendly_name // "")"'
```

## Then look at it

The capture is only half the job — **read the saved file** so you can actually
describe what is in the frame. A message saying "snapshot saved to
/config/www/snapshots/front_door.jpg" answers nothing the user asked.

Describe what is visibly there and be honest about what the image cannot
settle: night frames are noisy and IR-lit, wide-angle lenses distort distance,
and a still cannot distinguish "parked" from "just arrived". If the frame is too
dark or obstructed to answer the question, say so and offer to re-capture rather
than guessing.

## Where to write the file

The default `/config/www/snapshots/` is convenient but public-ish: everything
under `/config/www` is served by Home Assistant at `/local/`, with no
authentication. On an instance exposed to the internet, anyone with the URL can
fetch the file, and it stays there until deleted.

So choose deliberately:

- **Just looking at it now** → write to `/tmp/` or `/config/claude-snapshots/`.
  Nothing is served, and `/tmp` is cleared when the container restarts.
- **The user wants it in a dashboard card or a notification** → `/config/www/`
  is the right place, because that is what makes the URL work. Mention that it
  is reachable at `/local/snapshots/<file>.jpg`.

Interior cameras and anything showing people deserve the first option by
default. Clean up snapshots you created for your own inspection.

## Repeat captures

Filenames are deterministic, so a second `ha-snapshot camera.front_door`
overwrites the first. When comparing across time — did the parcel arrive, has
the car moved — pass explicit distinct paths:

```bash
ha-snapshot camera.drive /tmp/drive-before.jpg
sleep 300
ha-snapshot camera.drive /tmp/drive-after.jpg
```

For anything recurring ("check the driveway every morning"), do not sit in a
sleep loop — schedule it with `claude-cron` (see the **claude-scheduled-tasks**
skill) or drive it from a Home Assistant automation through the Automation API.

## Related

- Motion/occupancy history for the same spot: `ha-memory` (**ha-history** skill).
- Announcing what you found on a speaker: `ha-tts` (**ha-announce** skill).
