# MootTodo — A Friendly Guide

## What it is

MootTodo is a small to-do app. You add tasks. You check them off. That part is
ordinary.

The cool part is hidden underneath. While the app keeps your to-do list in its
own little file, it also copies every change into a second place called a
**MOOT**. A MOOT is a memory that you can search. So the app slowly builds up a
searchable record of everything you ever did — without much extra code.

We call this the **sidecar** pattern. Picture a motorcycle with a sidecar. The
to-do list is the motorcycle. The MOOT is the sidecar riding along next to it,
catching a copy of everything.

## How it works

There are two stores:

1. **Your to-do list.** A plain file. This is the truth about your tasks.
2. **The MOOT.** A parallel memory. Every time you add or check off a task, the
   app also files a copy here, like `TODO: Buy milk [done]`.

The copying is only about five lines of code. That is the whole point: you get a
searchable memory almost for free, just by copying as you go.

At the bottom of the screen there is a **Search memory** box. When you type in
it, the app asks the MOOT, not the to-do list. So you can search across
everything the app remembers, even old states.

When the app starts for the very first time, it adds three sample tasks so you
have something to play with right away.

## What to try

1. Open the app. You will see three sample tasks already there.
2. Add a task. Type a name and tap **Add**. Watch the little line at the bottom
   say it was mirrored into the MOOT.
3. Tap a task to check it off. The MOOT learns the new "done" state too.
4. Type a word like `milk` in the **Search memory** box and tap **Search**. The
   results come from the MOOT, not the list.
5. Try the voice shortcuts. Say "Capture in MootTodo" to save a memory, or
   "Recall in MootTodo" to search one. These talk to the same MOOT the app uses.

## One thing to know

The search results look a bit raw — each line shows an id, a room name, and a
preview. That is because the MOOT answers in plain text today, not in tidy
objects. A real app would clean this up. We left it raw so you can see exactly
what the MOOT sends back.
