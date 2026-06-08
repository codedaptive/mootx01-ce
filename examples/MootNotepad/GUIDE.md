# MootNotepad — A Friendly Guide

## What is it?

MootNotepad is a simple notes app. You write a note. It saves. You see it in a
list. You can search your notes or delete them.

The fun part is what holds the notes. Most apps use a database you have to set
up. This app uses **MOOT** as its only store. MOOT is a memory engine. Every
note you write becomes one "drawer" inside MOOT.

So when you read this app's code, you are learning how to build a real app where
MOOT is the whole filing cabinet.

## How does it work?

Think of MOOT as a filing cabinet with rooms. This app uses one room called
**notes**.

- **Write a note.** The app hands your text to MOOT and says "file this in the
  notes room." MOOT makes a drawer and gives back an id.
- **See your notes.** The app asks MOOT "show me what is in the notes room."
  MOOT answers with text, one line per note. The app reads those lines and
  turns each one into a row you can tap.
- **Delete a note.** The app tells MOOT "withdraw the drawer with this id." The
  note goes away.

The app never keeps its own copy of the truth. After every change, it asks MOOT
again. That way the screen always shows what MOOT really holds.

## One tricky bit (worth knowing)

When the app asks MOOT for the notes, MOOT replies with **text**, not with neat
note objects. Each line looks like this:

```
<id>  [notes]  the start of your note...
```

So the app has to read that text and pull out the three parts: the id, the room,
and a short preview. There is a small piece of code that does this. It is called
the parser. In a perfect world MOOT would hand back ready-made note objects, but
for now we read the text. The code points this out where it happens.

Also, the line only shows the **start** of a long note (a preview), not every
word. For this small app, that preview is the note we show.

## What to try

1. **Run it.** The first time, three sample notes appear. They were filed into
   MOOT for you so the app is not empty.
2. **Add a note.** Tap the pencil. Type something. Tap Save. Watch it appear.
3. **Search.** Type in the search box at the top. The app asks MOOT for matches
   as you type.
4. **Delete.** Swipe a note to the left and tap Delete. It is withdrawn from
   MOOT.
5. **Use your voice.** Try saying: "Hey Siri, take a note in MootNotepad." The
   note Siri files shows up in the app's list, because Siri and the app share
   the same MOOT.
6. **Watch the count.** The small text at the top of the list comes straight
   from MOOT. Add and delete notes and watch it change.

## Where are the notes kept?

In one SQLite file inside the app's private storage:

```
MootNotepad/notepad.sqlite
```

Delete that file and the app starts fresh, with the three sample notes again.
