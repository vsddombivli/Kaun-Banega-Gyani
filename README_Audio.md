# Audio cues

Drop your downloaded clips here with these EXACT filenames — `screen.html`
references them directly, no code changes needed once they exist.

| Filename            | When it plays                                   | Suggested length |
|----------------------|--------------------------------------------------|-------------------|
| question-in.mp3      | A new question appears on screen                 | 1-3s              |
| buzzer-open.mp3       | The 15s buzz-in window opens                     | 1-2s              |
| buzz-in.mp3           | A team is the first to press their buzzer        | 0.5-1s            |
| correct.mp3           | Answer revealed correct                          | 1-2s              |
| wrong.mp3              | Answer revealed wrong                            | 1-2s              |
| lifeline.mp3           | Any lifeline is activated                        | 1-2s              |
| tick.mp3                | Last 5 seconds of any countdown (plays once/sec) | <1s               |
| round-end.mp3           | A round ends / the next round begins             | 2-4s              |

Notes:
- MP3 works everywhere; keep files small (a few hundred KB each) so they load instantly.
- Missing files fail silently — the page won't error, that cue just stays silent until you add it. Add them one at a time and refresh to test.
- Only `screen.html` plays sound (the device connected to your speakers/projector). Team and audience devices stay silent by design — imagine 50 phones all beeping at once.
- Browsers block audio until the page gets a tap/click. `screen.html` shows a "Tap anywhere to enable sound" overlay once on load — the operator needs to tap it before the event starts.
