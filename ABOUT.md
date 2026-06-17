# About MOOTx01

*A long-term memory model for AI.*

---

You have had the moment.

Three weeks into a project with your AI. You have explained the same constraint four times. You explain it a fifth and it nods and forgets again. You come back to the chat that solved the problem last Tuesday and the AI does not know you. You switch tools because a new one is supposedly better, and you have to start over. Every preference, every piece of context, every thing your last AI finally understood. Gone.

You felt something. A specific kind of anger. Not at the AI. At the waste.

That feeling has a cause. The cause has a shape.

## The shape of the gap

Your AI has a context window. The context window is short. It holds only what fits inside one chat. When the chat ends, the window closes. The next chat starts from nothing. That is short-term memory. It is what your AI thinks with. To remember from, your AI needs something else.

To work around the forgetting, the AI industry built RAG. RAG is a big database in deep storage. When the AI needs an old fact, it goes searching. RAG works as far as it goes. But it is slow, it costs money on every call, and it gets things wrong often enough that you stop trusting it. Two years and billions of dollars have not made it feel like memory. It still feels like searching.

What your AI is missing is a layer. The layer between the short-term window and the deep archive. The layer that consolidates. The layer that prepares. The layer that already knows what mattered before you ask.

## You have this layer. You use it every night.

When you go to bed, your mind does not start fresh in the morning. The day is already sorted. You know what mattered. You know what to bring forward. You did not do that work consciously. Something else did it while you slept.

That something is your subconscious. It runs cheap deterministic passes over yesterday. It surfaces themes. It strengthens what repeats. It lets the small stuff fade. When your conscious mind wakes up, your memory is already prepared.

Your AI does not have a subconscious.

That is the gap. That is why you felt the rage. Every time you re-explain. Every time you re-introduce yourself. Every time you watch your AI search the basement for the same answer it gave you yesterday.

What fills the gap has to be yours. Not parked in someone else's cloud. Not readable by whoever owns the servers. Not gone if the vendor changes their mind. Your memory belongs where you put it. On your laptop. On your phone. On a home server. On a machine in a closet. Wherever you say.

## Imagine your AI had that layer.

It captures every conversation exactly as it happened. In the words it happened in. Without paraphrase. Without silent rewriting. What you said stays said.

While you sleep, the layer consolidates. Themes surface from your week. Connections strengthen between things that turned out to matter. The map of what connects to what reweighs itself against what actually happened. By morning, the answer to tomorrow's question is already prepared.

When you ask, your AI remembers. It returns ranked signal that the layer organized while you were not looking.

You just imagined a system. It has four behaviors. It observes. It remembers. It dreams. And it convenes.

That system is MOOTx01.

## The name

A **moot** was the old assembly where a community brought its memory together — witnessed events, sworn oaths, who decided what last winter. The record lived in the gathering. Modern English kept the word but lost the meaning. We're taking it back, because the older meaning is what memory actually is: observed over time, kept exactly as it was, available across every AI you use.

**You are x01.** Hex 01, first person — the hero of your story, and your MOOT is the gathering of it. There is no MOOTx02; you don't get upgraded to a later you. Your spouse is x01 in theirs, your calendar app is x01 in its domain, and when you authorize it, the MOOTs convene.

## You are x01

Hex 01. First person. You are the hero of your story, and your MOOT is the gathering of it.

There is no MOOTx02. You do not get upgraded to a later version. You are x01 in your story, your spouse is x01 in theirs, your colleague is x01 and the pattern continues. Every MOOT begins at first person because every memory does.

You can have more than one MOOT. A work MOOT and a home MOOT, discrete and separate. They do not bleed into each other. The work MOOT does not know about the dentist appointment. The home MOOT does not know about the quarterly review. That separation is not a setting; it is the architecture.

But MOOTs can gather. Your home MOOT knows your child's school schedule. Your spouse's home MOOT knows they made a tentative plan for summer camp they have not told you about yet. When the question comes up — "what does June look like?" — your MOOT and their MOOT can convene. Each brings what it knows. The plan surfaces. Nothing was centralized. No app coordinated. The two MOOTs gathered, briefly, securely, privately, automatically. Afterward, your MOOT still belongs to you. Their still belongs to them. The household knows what the household needed to know.

The same rule applies to anything with a perspective. Your calendar app is x01 in its own domain. Your project tracker is x01 in its own. Each application can hold its own MOOT — its own first-person record of what it knows. When you authorize it, your personal MOOT can convene with any of them. The calendar's MOOT brings what it knows about your week. The project tracker's MOOT brings what it knows about what is due. Your MOOT gathers what you allowed across them all.

In most cases, you do not need application developers to do anything special. If your calendar exposes its knowledge through the Model Context Protocol — and most modern productivity tools either do or will — your AI can read from it through ARIA and bring what it learns into your MOOT. You did not have to wait for the calendar app to rewrite itself.

You decide what crosses. The work MOOT stays out of the home MOOT until you say otherwise. The finance app's MOOT does not enter the household conversation unless you bring it in. Every convening is bounded by what you authorized. The gathering belongs to you because you are the one who called it.

## For developers

If you are building an application and you want it to have temporal knowledge — the kind of memory that survives sessions, links to AI, and participates in the user's life — you can embed MOOTx01 directly.

Most applications do not have a memory substrate because writing one is hard. The math debt is steep. The speed optimization is harder. Most teams cannot afford to do it themselves, and most who try do it badly.

You do not have to. MOOTx01 ships as a kit family. Your application gets its own MOOT — first-person to your application's domain — and shares whatever the user authorizes with the user's personal MOOT. You focus on what your application does. The substrate is already done.

The interface is called ARIA. It is consistent across implementations, across consumption surfaces, across languages. The same vocabulary works whether your application embeds MOOTx01 as a library, queries it through an MCP server, or calls it through a native API.

## Tomorrow

You open your AI. It already knows who you are. Last night, while you slept, MOOTx01 consolidated everything you and your AI worked on this week. The themes surfaced. The decisions ranked. The recall is prepared the moment you sit down.

You ask a question. The AI doesn't ask you to re-explain. It doesn't search the basement. It reads from your MOOT through ARIA, the shared language every AI tool and application uses to talk to your memory. What comes back is ordered thought, not chaotic data. Your AI reasons on signal instead of noise. Faster. More accurate. Cheaper per call. And tomorrow's recall is better than today's, because the subconscious kept working overnight.

You switch AI tools next month. Your memory comes with you. Your MOOT is yours, and any AI that speaks ARIA can read from it. The intelligence is rented. The memory is owned.

## The promise

You've heard a promise like this before. The promise needed a memory architecture nobody had built.

We built it.

MOOTx01 runs where you do. Your laptop, your phone, your home server, wherever your AI lives. Through ARIA, any AI that speaks the Model Context Protocol reads from your memory: Claude, ChatGPT, a local model you run yourself, eventually Siri once Apple ships MCP support. The basement archive is still there underneath for the rare case you need chaos. The default is signal.

MOOTx01 understands the data of your life. If you want to be Tony Stark, your AI can be Jarvis.

Memories observed over time. A gathering of what was seen, kept exactly as it was, ready before you ask.

---

## Acknowledgments

0x1B0B — to Dennis E. Taylor, author of the Bobiverse, for reminding me that moots have value. The replicants and their gatherings showed me the shape of what we need and why we need it.

---

MOOTx01 is a [Codedaptive](https://codedaptive.com) project.
