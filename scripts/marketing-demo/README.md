# Public demo fixture

Run `scripts/marketing-demo/build` on macOS. The app is created at
`/tmp/codexbar-marketing-demo/CodexBar Public Demo.app`.

The fixture compiles the production `TaskListView`, `GitWorkspaceRowContent`,
`TaskDetailCard` (including Markdown, scroll and tool expansion), and
`KnowledgeLibraryView` unchanged.
`DemoModels.swift` replaces the runtime-facing models with fictional in-memory
data. Its four independent workspace rows use the shared layout and Git tree
projections with fictional labels: Atlas has `main → graph-runtime → graph-ui`,
and Studio is a separate project. The fixture does not read Git metadata.
No user defaults, app monitors, file watchers, vaults, VS Code windows,
Obsidian URLs, shell commands or network clients are accessed by the demo.
Task navigation selects a matching fictional project card inside the demo;
other external navigation controls deliberately do nothing.

The opaque window contains a synthetic background. Its demo-only material uses
`withinWindow`, never the production `behindWindow`, so glass cannot sample the
real desktop. The task strip in the first scene is enlarged for readability;
the project card behind it is labeled as illustrative.

Capture only this demo window with an authorized app capture tool. Do not capture
the desktop or the user's real CodexBar application. Every frame carries the
fictional-data label. Generated media belongs in `docs/images/`; the build output
and raw captures should remain outside the repository.

## Task walkthrough

The README leads with `docs/images/task-demo.gif`. Its eight native window
captures were recorded on 2026-09-14:

1. Show the enlarged task strip with three Atlas branches and independent Studio.
2. Open the **graph-ui** context menu and choose **查看任务详情**. The production
   preview shows its full branch name, creation source, path and fictional reply.
3. Expand **工具完成 · 演示检查**, then click **回到最新** to show the complete output.
4. Click **切到项目** to select the illustrative graph-ui project card.
5. Click the native **main** row to select its project card.
6. Click **graph-runtime** to select that worktree's card.
7. Click **graph-ui** to return to its card.
8. Click **继续演示任务**: graph-ui becomes running, graph-runtime becomes ready to
   review, and the remaining tasks retain their statuses.

The frames are held for 2.6 / 3.2 / 2.2 / 2.4 / 1.6 / 1.6 / 1.2 / 3.2 seconds
(18 seconds total). This is an edited sequence of actual native window captures,
not a continuous recording of live Codex traffic. Task rows, branch connections,
context menus and conversation controls use the production views. Project-window
selection and status changes are in-memory demonstrations; they do not exercise
real VS Code window activation or actual Git discovery.

Every frame includes **原生界面 · 虚构数据 · 窗口场景示意**. The capture is limited to
the opaque 1024×760-pixel demo window, excluding the real desktop. UI pixels are
not reconstructed or redrawn. Source display profiles are converted to generic
sRGB, then discarded along with all other source metadata. The looping GIF uses
a shared 256-color palette (192 median-cut colors plus 64 maximum-coverage colors
to preserve small status indicators), without dithering, and is about 1.04 MB.
`task-demo-poster.png` shows the
opening frame. Raw captures remain outside the repository.

The right arrow or **下一幕** advances through overview, preview, illustrative
project selection and status update, then the knowledge scenes. **重播** restores
all fixture data. The demo generates no screenshots or recordings itself.
Review every exported frame and its metadata before publication, then use
**Cmd+Q** to quit only the demo application.

## Knowledge recording

The independent knowledge-library section keeps the existing native close-up
GIF. Its six interaction states come from the native window captures recorded
on 2026-09-12:

1. Open the book button and capture all libraries with their initial unread counts.
2. Select **Anthropic** to read three article summaries and clear its count.
3. Select **Hugging Face** to read its two summaries and clear only its count.
4. Select **LangChain** to read its article and clear its count.
5. Click **刷新知识库** to inject an Anthropic article while LangChain stays selected.
6. Select **Anthropic** to read the new article and clear the new count.

The production knowledge view keeps its 600×520-point viewport. Every article in
the fixture has a fictional summary. The real app extracts this paragraph from
Markdown; the fixture supplies it in memory without reading any local notes.

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
