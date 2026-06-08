# MootCalendarIngest — Friendly Guide

## What is this?

This is a small app that gives your calendar a memory.

Apple Calendar is an app you cannot change. You do not own its code. But it
holds something useful: your events. This app reads those events and copies them
into the MOOT — a memory store you *do* control. Your calendar is never changed.
We only read it. Think of it like taking notes from a book without writing in the
book.

## How does it work?

There are two sides:

- **Reading:** The app asks iOS for permission to look at your calendar. Then it
  reads this week's events. That is all it does to the calendar — look.
- **Writing:** For each event, the app files a little note into the MOOT. The
  note says the event's name and time. Now the event lives in your memory store,
  and you can search for it.

After that, you can type a word like "lunch" and the MOOT finds the event. The
calendar did not change. The memory is the new part.

## What should I try?

Do these in order:

1. Tap **Grant calendar access**. Say yes to the permission box.
2. The simulator's calendar is empty, so tap **Seed sample events**. This makes
   three pretend events for this week. This is the only time the app adds
   anything to the calendar.
3. Tap **Load this week's events**. You will see the three events in a list.
4. Tap **Sync this week to MOOT**. The app copies each event into the MOOT. It
   tells you how many it copied.
5. Type a word like **standup** or **lunch** in the search box and tap
   **Search**. The MOOT shows you the matching event. It is now a memory.

## You can also ask Siri

Because this app registers shortcuts, you can say:

- "Recall memories in MootCalendarIngest" — Siri searches the same MOOT, so it
  finds your calendar events too.
- "Capture a memory in MootCalendarIngest" — file any note by voice.

## The one thing to remember

The calendar is never touched. The memory is built next to it, in the MOOT. That
is the whole trick: old app, new memory.
