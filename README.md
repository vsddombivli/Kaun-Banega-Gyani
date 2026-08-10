# VSD Kaun Banega Gyani — Quiz System

Realtime KBC-style quiz platform: Admin control room, projector presentation, team buzzer devices, audience poll, and team registration — all backed by Supabase (Postgres + Realtime + RPC functions as the server-authoritative layer).

## What's actually here (and what isn't)

Built: event/round/question management, admin control room, buzzer engine (30s window, first/second team, one pass, no third), audience poll with live percentage reveal, manual + rule-based scoring with audit log, lifeline unlock/use/revive, team registration with atomic name-claiming, presentation screen for all of the above.

Not built, and you should scope separately before the event: the Phase 7 rehearsal/simulation harness, KBC background audio (spec explicitly leaves this to your own audio setup), and a picture-round admin UI beyond the generic `image_url` field on a question (it works, but there's no dedicated "spot the mistake" annotation tool).

## 1. Supabase setup

1. Create a project at supabase.com.
2. Open **SQL Editor** and run the entire `supabase-schema.sql` file once.
3. Go to **Authentication > Users** and create an admin user (email + password).
4. Copy that user's UID (Authentication > Users, click the user), then run in SQL Editor:
   ```sql
   insert into public.admins (user_id, name) values ('<paste-uid-here>', 'Volunteer Name');
   ```
5. Create your event and seed data (also in SQL Editor — uncomment/edit the block at the bottom of `supabase-schema.sql`, or run manually):
   ```sql
   insert into public.quiz_events (event_name, event_date, status)
     values ('VSD Prabhu Pooja & Guru Vandan Quiz', current_date, 'LIVE')
     returning id; -- copy this id for the next two inserts

   insert into public.quiz_session (event_id) values ('<event-id>');

   insert into public.quiz_team_names (event_id, team_name)
     values ('<event-id>','NAVKAR'), ('<event-id>','ARIHANT'), ('<event-id>','MAHAVIR'), ('<event-id>','SIDDHARTH');

   insert into public.quiz_lifeline_milestones (event_id, points_threshold, unlocks) values
     ('<event-id>', 100, 'FIFTY_FIFTY'), ('<event-id>', 300, 'AUDIENCE'),
     ('<event-id>', 500, 'EXPERT'), ('<event-id>', 750, 'TEAM_ADVICE'), ('<event-id>', 1000, 'REVIVE');
   ```
6. In **Project Settings > API**, copy your Project URL and `anon` public key into `shared/supabase-client.js`.
7. In **Project Settings > API > Realtime**, make sure Realtime is enabled (the schema script already adds the needed tables to `supabase_realtime`).

## 2. Hosting

Any static host works (Netlify, Vercel, GitHub Pages, or a plain folder served over HTTPS — Supabase requires HTTPS for most browsers' camera/QR features if you add QR scanning later). Upload the whole folder as-is; the pages reference `shared/` with relative paths.

## 3. Pages

| Page | URL | Who uses it |
|---|---|---|
| `register.html` | `/register` | Parents, before the event |
| `admin.html` | `/admin` | Quiz director (needs login) |
| `screen.html` | `/screen` | Projector/LED, fullscreen |
| `team.html` | `/team` | One device per team, enter team code |
| `audience.html` | `/audience` | Audience phones, QR code to this URL |

## 4. Operating the buzzer round (what actually happens under the hood)

Every buzzer press, vote, and state transition goes through a Postgres `SECURITY DEFINER` function (see section 4 of the schema), not a raw table write. That's what makes it server-authoritative: a team's device clock, a slow connection, or a modified client can't move the deadline or fabricate an earlier timestamp — `submit_buzzer` checks `now() >= timer_end` against the database's own clock before accepting a press, and a unique constraint blocks a second press from the same team. The one soft spot: closing the buzzer relies on *any* connected client calling `try_close_buzzer` after the deadline (there's no cron job) — the presentation screen, team devices, and admin panel all do this automatically, so in practice it closes within a few hundred milliseconds of expiry, but if every client's tab were somehow closed simultaneously it wouldn't self-close. Not a realistic scenario with a live audience, but worth knowing.

## 5. Before the actual event

Run a full rehearsal with real devices on the real venue Wi-Fi: two teams buzzing within the same second, a team device losing signal mid-question, an audience member trying to vote twice, and an admin refreshing mid-question. The spec calls this out as a hard requirement (section 22, Phase 7) and it's the right call — this system has no backend server to restart if something wedges, only Postgres state, so you want to know what "recovery" (the `RESET QUESTION` button) actually looks like on stage before you're in front of 200 people.
