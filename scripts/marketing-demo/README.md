# Public demo fixture

Run `scripts/marketing-demo/build` on macOS. The app is created at
`/tmp/codexbar-marketing-demo/CodexBar Public Demo.app`.

The fixture compiles the production `TaskListView`, `TaskDetailCard` (including
Markdown, scroll and tool expansion), and `KnowledgeLibraryView` unchanged.
`DemoModels.swift` replaces the runtime-facing models with fictional in-memory
data. No user defaults, app monitors, file watchers, vaults, VS Code windows,
Obsidian URLs, shell commands or network clients are accessed by the demo.
External navigation controls deliberately do nothing.

The opaque window contains a synthetic background. Its demo-only material uses
`withinWindow`, never the production `behindWindow`, so glass cannot sample the
real desktop. The task strip in the first scene is enlarged for readability;
the project card behind it is labeled as illustrative.

Capture only this demo window with an authorized app capture tool. Do not capture
the desktop or the user's real CodexBar application. Every frame carries the
fictional-data label. Generated media belongs in `docs/images/`; the build output
and raw captures should remain outside the repository.

1. Capture the opening task overview.
2. Click **Notes** for the production conversation preview.
3. Click **工具完成 · 演示输出** to expand the fictional tool result.
4. Click **回到最新** to show the complete expanded output.
5. Click the book button to show the knowledge list with unread counts.
6. Click **Anthropic**: its count clears and article titles with paragraph summaries appear.
7. Click **刷新知识库**: the fixture injects a new fictional article with a summary,
   and the selected library's unread count becomes 1.
8. Click **Anthropic** again: that new count clears while all four articles remain.

The production knowledge view keeps its 600×520-point viewport. Every article in
the fixture has a fictional summary. The real app extracts this paragraph from
Markdown; the fixture supplies it in memory without reading any local notes.

The right arrow key also advances a scene. The reset button restores fixture
data. The demo generates no screenshots or recordings itself.

The README recording was refreshed on 2026-09-12 using Computer Use to operate
and capture only the running demo app window. It uses eight captured interaction
states, held for 2.5 / 2.8 / 0.7 / 2.4 / 2.4 / 4.6 / 4.6 / 3.0 seconds
(23 seconds total). This is an edited sequence of real window captures, not a
continuous screen recording or a capture of live Codex task traffic.
Frames are converted to generic sRGB and encoded as a looping GIF with
a shared 256-color palette. The GIF and poster are 1024×760 pixels; the GIF is
about 1.9 MB. The static poster shows the selected knowledge base and its summaries.
Both outputs omit source metadata, including display profiles; raw captures are
not published. Review every frame for unintended content before replacing either
asset. Use **Cmd+Q** to quit the demo after capture.

## Knowledge close-up

`docs/images/knowledge-demo.gif` is a separate recording of the same running
production view with fictional data. Open the book button, then capture:

1. All libraries with their initial unread counts.
2. Select **Anthropic** to read three article summaries and clear its count.
3. Select **Hugging Face** to read its two summaries and clear only its count.
4. Select **LangChain** to read its article and clear its count.
5. Click **刷新知识库** to inject an Anthropic article while LangChain stays selected.
6. Select **Anthropic** to read the new article and clear the new count.

This GIF contains six actual window captures held for 2 / 3 / 3 / 2.5 / 2.5 / 4
seconds (17 seconds total). Each capture crops the knowledge viewport with its
border, and places the captured fictional-data footer below it. The UI pixels
are not reconstructed or redrawn. The output is 616×576 pixels, about 738 kB,
with a shared 256-color palette, infinite looping and no source metadata.
The complete 23-second demonstration remains available as `demo.gif`.
