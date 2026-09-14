# Public demo fixture

Run `scripts/marketing-demo/build` on macOS. The app is created at
`/tmp/codexbar-marketing-demo/CodexBar Public Demo.app`.

The fixture compiles the production `TaskListView`, `GitWorkspaceRowContent`,
`TaskDetailCard` (including Markdown, scroll and tool expansion), and
`KnowledgeLibraryView` unchanged.
`DemoModels.swift` replaces the runtime-facing models with fictional in-memory
data. Its three independent workspace rows use the shared layout projection
without reading Git metadata. No user defaults, app monitors, file watchers, vaults, VS Code windows,
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

## README recording

The README leads with the task workflow illustration in `overview.svg`; its
knowledge-library section keeps the existing native close-up GIF. Its six interaction states
come from the native window captures recorded on 2026-09-12:

1. Open the book button and capture all libraries with their initial unread counts.
2. Select **Anthropic** to read three article summaries and clear its count.
3. Select **Hugging Face** to read its two summaries and clear only its count.
4. Select **LangChain** to read its article and clear its count.
5. Click **刷新知识库** to inject an Anthropic article while LangChain stays selected.
6. Select **Anthropic** to read the new article and clear the new count.

The production knowledge view keeps its 600×520-point viewport. Every article in
the fixture has a fictional summary. The real app extracts this paragraph from
Markdown; the fixture supplies it in memory without reading any local notes.

The right arrow key also advances a scene. The reset button restores fixture
data. The demo generates no screenshots or recordings itself.

The README reuses these recorded knowledge interactions in the independent
knowledge section. The task workflow is explicitly labeled as an illustration;
it does not claim a new recording of task switching or focus behavior.

The six frames are held for 1.8 / 4.5 / 3.5 / 2.8 / 3.0 / 4.4 seconds
(20 seconds total). This is an edited sequence of real window captures, not a
continuous screen recording or a capture of live automation traffic. Each frame
crops the knowledge viewport with its border and places the captured fictional-data
footer below it. The UI pixels are not reconstructed or redrawn.

Frames are converted to generic sRGB and encoded as a looping GIF with a shared
256-color palette. `docs/images/demo.gif` and `demo-poster.png` are 616×576 pixels;
the GIF is about 738 kB. The poster shows Anthropic selected with its summaries.
Both outputs omit source metadata, including display profiles. Review every frame
for unintended content before replacing either asset. Use **Cmd+Q** to quit the
demo after capture.

`knowledge-demo.gif` retains the earlier 17-second cut of the same six knowledge
states; the README uses the 20-second cut above.

## Optional task walkthrough

For a future task recording, capture the opening task overview, then open the
**Notes** context menu and choose **查看任务详情**. The production task strip offers
focus through its row menu, and the conversation preview's navigation button reads **切到项目**.
Expand **工具完成 · 演示输出**, then click **回到最新** to read the complete result.
These views use fictional data; the fixture does not exercise real VS Code
window switching or minimization.
