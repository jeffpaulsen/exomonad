# Notes: Simon Willison's Agentic Engineering Patterns

## 1. What is Agentic Engineering?

- **Definition**: "The practice of developing software with the assistance of coding agents"
- Agent = "runs tools in a loop to achieve a goal" (LLM + tool execution + feedback loop)
- Code execution is the key differentiator — without it, LLM output has limited value
- Human role shifts from writing code to: deciding WHAT to write, weighing tradeoffs, selecting approaches, providing specs, verifying results
- Distinct from "vibe coding" (unreviewed prototype code) — agentic engineering is deliberate, production-quality

## 2. Writing Code is Cheap Now

- Code generation is nearly costless — disrupts traditional software economics
- Historical constraint: code was expensive to produce, shaped all planning/estimation
- New reality: previously uneconomical features become feasible. Parallel agents amplify this.
- **BUT**: "delivering new code has dropped to almost free... but delivering *good* code remains significantly more expensive"
- Good code = correct, tested, solves right problem, handles errors gracefully, simple, documented, future-proof, secure/accessible/maintainable
- Advice: reconsider decisions previously rejected as too time-consuming. Run experimental agent sessions async — worst case you learn it wasn't worth it.

## 3. Hoard Things You Know How to Do

- Build a personal repository of working code examples demonstrating feasible approaches
- "The best way to be confident is to have seen them illustrated by running code"
- Willison uses: blog, TIL site, 1000+ GitHub repos with small prototypes, tools site
- **Recombining examples** is the power move: give an agent two working code snippets and ask it to combine them into something new
- Example: combined Tesseract.js (browser OCR) + PDF.js (PDF→image) into a single drag-and-drop OCR tool
- "Coding agents mean we only ever need to figure out a useful trick once" — the hoard becomes a force multiplier

## 4. AI Should Help Us Produce Better Code

- "Shipping worse code with agents is a *choice*. We can choose to ship code that is better instead."
- Technical debt that's conceptually simple but time-consuming is ideal for agents: API redesigns, renames, dedup, file splitting
- Improvement costs have plummeted → "zero tolerance attitude to minor code smells" becomes feasible
- Agents expand solution discovery: rapid prototypes to validate tech choices through testing, not guesswork
- **Compound engineering loop**: document what works per project → institutional knowledge improves future agent runs → compounds over time

## 5. Anti-patterns: Things to Avoid

- **Core anti-pattern**: Filing PRs with hundreds/thousands of lines of agent-generated code without personal review
- "They could have prompted an agent themselves. What value are you even providing?"
- Good agentic PRs: (1) verified functionality, (2) small scope, (3) additional context/explanation, (4) personally reviewed descriptions (agents write convincing but potentially inaccurate text)
- Demonstrate your work: testing notes, implementation comments, visual documentation

## 6. How Coding Agents Work

- Agent = LLM harness with tools in a feedback loop. "Agents run tools in a loop to achieve a goal"
- LLMs are stateless — software replays entire conversation each turn. Costs grow with conversation length.
- **Token caching**: repeated prefixes reuse expensive calculations. Agents designed to maintain earlier content for cache efficiency.
- **Tools** are the defining feature: model generates structured tool calls, harness executes, returns results as context
- System prompts: hidden instructions, can span hundreds of lines detailing tools and behaviors
- **Reasoning/thinking**: 2025 advance — models generate intermediate reasoning before responding, spending tokens on debugging and complex paths
- The whole thing is just: LLM + system prompt + tools in a loop. Can be built in dozens of lines.

## 7. Subagents

- Solve the context limit problem: dispatch fresh LLM instances with independent context windows for specific tasks
- Context limits top out ~1M tokens, but benchmarks show better quality below 200K — careful context management essential
- Subagent = "dispatches a fresh copy of itself with a new context window starting with a fresh prompt"
- Parent treats subagents like any other tool
- Example: Claude Code's Explore subagent maps codebase structure with fresh prompt
- **Parallel subagents**: run simultaneously for independent tasks. Works well with faster/cheaper models (Haiku).
- **Specialist subagents**: code reviewers, test runners, debuggers — but don't overuse
- "The main value of subagents is in preserving that valuable root context and managing token-heavy operations"
- **Key insight**: subagents are context window management, not just parallelism

## 8. Red/Green TDD

- "Red/green TDD" as a concise instruction significantly improves coding agent performance
- Red phase: write tests, confirm they FAIL (validates the test actually tests something)
- Green phase: implement code to make tests pass
- Prevents: non-functional code, unnecessary code, missing test coverage
- Quality models recognize "red/green TDD" as shorthand for the full workflow
- Example prompt: "Build a Python function to extract headers from a markdown string. Use red/green TDD."
- Skipping red phase risks tests that already pass → doesn't validate new implementation

## 9. First Run the Tests

- Run tests as FIRST step with coding agents on existing projects
- Traditional objections to writing tests (time-consuming) no longer apply — agents update them quickly
- Tests help agents understand codebases (serve as documentation)
- Agents naturally inclined toward testing; existing test suite pushes them to test new changes
- **Four-word prompt**: "First run the tests" — accomplishes 3 things:
  1. Shows test suite exists, forces agent to learn how to run it
  2. Reveals project scope/complexity via test count
  3. Establishes testing-focused mindset

## 10. Agentic Manual Testing

- "Never assume that code generated by an LLM works until that code has been executed"
- Code can pass all tests yet fail in obvious ways — manual testing catches what automated tests miss
- Testing mechanisms: `python -c "..."` for libraries, `curl` for APIs, browser automation for UIs
- Browser tools: Playwright, agent-browser (Vercel), Rodney (Simon's tool with screenshots)
- **Showboat**: documentation tool for agentic testing — `note` (markdown), `exec` (records commands + output, prevents fabrication), `image` (screenshots)
- Issues found via manual testing → fix with red/green TDD → permanent automated coverage

## 11. Linear Walkthroughs

- Use agents to create structured walkthroughs of codebases you need to understand
- Works for: forgotten projects, vibe-coded apps, inherited codebases
- Pattern: agent reads source, plans a linear walkthrough, documents with Showboat (note + exec commands)
- Key: use `grep`, `sed`, `cat` for code snippets rather than agent copying — avoids hallucination
- Result: detailed explanation document that also teaches you the framework/language

## 12. Interactive Explanations

- **Cognitive debt**: losing track of how agent-generated code works. Complex algorithmic code demands clarity.
- Progressive understanding: raw code → linear walkthrough → animated visualization
- Breakthrough: have agents build **interactive HTML visualizations** that animate algorithms step-by-step
- Example: word cloud placement algorithm → animated HTML page showing spiral placement, collision detection, controllable speed
- "High-quality coding agents can generate explanatory animations on-demand, transforming abstract algorithms into understandable visual narratives"

## 13. GIF Optimization Tool (Annotated Prompt)

- Case study: building a browser-based GIF optimizer by compiling Gifsicle (30-year-old C tool) to WASM
- Prompt anatomy: filename first, leverage existing knowledge ("compile gifsicle to WASM"), describe UI patterns, smart defaults (trust agent's judgment on optimization settings), testing integration
- **Key insight**: "Coding agents work *so much better* if you make sure they have the ability to test their code while they are working"
- Used Rodney (browser automation) during development — agent identified and fixed bugs during testing
- Follow-up refinements: build scripts, patch management, attribution, licensing
- Shows the "hoard" pattern in action: combining known-working patterns (drag-drop UI, WASM compilation, Gifsicle CLI) into something new

## 14. Prompts I Use

- Artifacts: "Never use React in artifacts - always plain HTML and vanilla JavaScript and CSS" — enables easy copy to static hosting
- Proofreading: firm boundary that opinions/"I" pronouns must be human-written. LLMs proofread for spelling, grammar, repeated terms, weak arguments, broken links
- Alt text: Claude Opus drafts alt text, often making good editorial decisions about what to highlight. Human still edits.
- Theme: practical human-in-the-loop — AI assists rather than replaces judgment

---

## Cross-cutting Themes

1. **Context management is everything**: subagents, token caching, context preservation — the fundamental constraint is attention, not compute
2. **Test-driven agents**: red/green TDD + "first run the tests" + manual testing = quality assurance loop
3. **Compound knowledge**: hoard working examples, document what works, build institutional memory → each agent session gets better
4. **Human stays in the loop**: review all output, verify functionality, provide context. The shift is from writing to directing + verifying.
5. **Code execution is the differentiator**: agents that can run code iterate toward correctness; those that can't just generate text
6. **Small, focused PRs**: scope control matters more than ever with agents that can generate thousands of lines
