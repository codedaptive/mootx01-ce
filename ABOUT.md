# About MOOTx01

*A long-term memory model for AI.*

---

You've had the moment.

You're three weeks into a project with your AI. You've explained the same constraint four times. You explain it a fifth, and it nods, and on the next prompt it forgets again. Or you come back to the chat that solved the problem last Tuesday and it doesn't know you. Or you switch tools because the new one is supposedly better, and you realize you have to start over. Every preference, every piece of context, every thing your last AI finally understood, gone.

You felt something. A specific kind of anger. Not at the AI, exactly. At the waste.

That feeling has a cause. And the cause has a shape.

Your AI has a context window. It is sharp, expensive, and short. Everything in it has to be there right now, paid for by the token. When the conversation ends, the window closes, and the next conversation starts from nothing. That is short-term memory. It is what your AI thinks with. It is not what your AI remembers from.

To paper over the forgetting, the industry built RAG. A vector database in deep storage. When the AI needs something obscure, it goes searching. RAG works, as far as it goes, but it is the basement archive, full of raw tape. The AI filters everything at the moment you ask, on every call, from chaos. Slow. Expensive. Context-dependent accuracy at best. And despite billions of dollars in investment, RAG still struggles to feel like memory because it retrieves on demand rather than preparing what you need before you ask.

The thing your AI is missing isn't a feature. It's a layer.

## You have the layer. You use it every night.

When you go to bed, you don't reason about your day from a flat list of everything that happened. By morning, the day has already been sorted. You know what mattered. You know what to bring forward. You didn't do that work consciously; something else did it while you slept.

That something is your subconscious. It runs cheap deterministic processes on yesterday's experience. It surfaces themes. It strengthens what repeats. It lets the unimportant fade. When your conscious mind wakes up and reaches for memory, the memory is already prepared.

Your AI doesn't have a subconscious.

That's the gap. That's why the rage. Every time you re-explain, every time you re-introduce yourself, every time you watch your AI search the basement for the same answer it gave you yesterday. What's missing is the layer between the context window and the archive. The layer that consolidates. The layer that prepares. The layer that knows what mattered — because it watched what you and your AI actually used.

And whatever fills the gap has to be yours. Not parked in someone else's cloud, rented by the month, readable by whoever owns the servers, gone if the vendor changes their mind. Your memory belongs where you put it: on your laptop, your phone, your home server, a machine in a closet, a tenant you run yourself. Wherever you say. Always under your control.

## Imagine your AI had that layer.

It captures every conversation exactly as it happened, in the words it happened in. Verbatim. What you said stays said, in the words you said it, without paraphrase or summary or silent rewriting.

While you sleep, it consolidates. The matrix of what-connects-to-what reweighs itself against how your memory actually got used — connections strengthen between things you recalled together, themes surface from the co-occurrence of your week, the unimportant fades. By morning, recall is ranked by what mattered.

When you ask, it remembers. It returns ranked, filtered, theme-aware signal that the subconscious already organized while you weren't looking.

You just imagined a system. It has four behaviors. It observes, it remembers, it dreams, and it convenes.

That system is MOOTx01.

## The name

The name is a word from old English. A moot was the assembly where a community brought its memory together. An intersection of witnessed events, sworn oaths, who decided what last winter. The record lived in the gathering. The gathering was the record.

Modern English kept the word but lost the meaning; moot now means no longer relevant.

We are taking the word back, because the older meaning is what memory actually is: observed over time, kept exactly as it was, available across every AI you use.

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

You open your AI. It already knows who you are. Last night, while you slept, MOOTx01 consolidated the week's use of your memory. Themes surfaced from what you and your AI actually touched; the connections you leaned on grew stronger. The recall is prepared the moment you sit down.

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
