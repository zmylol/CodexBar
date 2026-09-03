function run(argv) {
    if (argv.length < 2 || argv.length > 3) {
        throw new Error("usage: make-test-event.js <running|attention|ready> <cwd> [title]");
    }

    const state = argv[0];
    const cwd = argv[1];
    const parts = cwd.split("/").filter(function (part) { return part.length > 0; });
    const workspace = parts.length > 0 ? parts[parts.length - 1] : "workspace";
    const safeWorkspace = workspace.replace(/[^A-Za-z0-9._-]/g, "-");
    const event = {
        session_id: "codexbar-test-" + safeWorkspace,
        turn_id: "manual-" + safeWorkspace,
        cwd: cwd,
        timestamp: new Date().toISOString()
    };

    if (state === "running") {
        event.hook_event_name = "UserPromptSubmit";
        event.prompt = argv[2] || ("Simulated task for " + workspace);
    } else if (state === "attention") {
        event.hook_event_name = "PermissionRequest";
        event.tool_name = "Bash";
        event.tool_input = { description: "Simulated permission request" };
    } else if (state === "ready") {
        event.hook_event_name = "Stop";
        event.stop_hook_active = false;
        event.last_assistant_message = "Simulated result available";
    } else {
        throw new Error("unsupported state: " + state);
    }

    return JSON.stringify(event);
}
