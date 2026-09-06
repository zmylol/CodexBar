ObjC.import("Foundation");

function unwrap(value) {
    return ObjC.unwrap(value);
}

function readConfiguration(path) {
    const manager = $.NSFileManager.defaultManager;
    if (!manager.fileExistsAtPath(path)) {
        return { hooks: {} };
    }

    const data = $.NSData.dataWithContentsOfFile(path);
    if (!data) {
        throw new Error("Unable to read " + path);
    }
    const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    if (!text) {
        throw new Error("hooks.json is not UTF-8");
    }

    let configuration;
    try {
        configuration = JSON.parse(unwrap(text));
    } catch (error) {
        throw new Error("hooks.json is malformed: " + error.message);
    }

    if (!configuration || Array.isArray(configuration) || typeof configuration !== "object") {
        throw new Error("hooks.json must contain a JSON object");
    }
    if (configuration.hooks === undefined) {
        configuration.hooks = {};
    }
    if (!configuration.hooks || Array.isArray(configuration.hooks) || typeof configuration.hooks !== "object") {
        throw new Error("hooks.json field 'hooks' must be an object");
    }
    return configuration;
}

function shellQuote(value) {
    return "'" + value.replace(/'/g, "'\\''") + "'";
}

function isCodexBarHandler(handler, executables) {
    if (!handler || handler.type !== "command" || typeof handler.command !== "string") {
        return false;
    }
    return executables.some(function (executable) {
        const base = shellQuote(executable);
        return handler.command === base
            || handler.command === base + " --probe"
            || handler.command === base + " --codexbar-managed"
            || handler.command === base + " --codexbar-managed --probe";
    });
}

function removeCodexBarHandlers(configuration, executables) {
    Object.keys(configuration.hooks).forEach(function (eventName) {
        const groups = configuration.hooks[eventName];
        if (!Array.isArray(groups)) {
            return;
        }

        const remainingGroups = [];
        groups.forEach(function (group) {
            if (!group || !Array.isArray(group.hooks)) {
                remainingGroups.push(group);
                return;
            }
            const remainingHandlers = group.hooks.filter(function (handler) {
                return !isCodexBarHandler(handler, executables);
            });
            if (remainingHandlers.length === group.hooks.length) {
                remainingGroups.push(group);
            } else if (remainingHandlers.length > 0) {
                const copy = Object.assign({}, group);
                copy.hooks = remainingHandlers;
                remainingGroups.push(copy);
            }
        });

        if (remainingGroups.length > 0) {
            configuration.hooks[eventName] = remainingGroups;
        } else {
            delete configuration.hooks[eventName];
        }
    });
}

function validateTargetEventGroups(configuration) {
    ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"].forEach(function (eventName) {
        const groups = configuration.hooks[eventName];
        if (groups === undefined) {
            return;
        }
        if (!Array.isArray(groups)) {
            throw new Error("hooks.json field 'hooks." + eventName + "' must be an array");
        }
        groups.forEach(function (group) {
            if (!group || typeof group !== "object" || !Array.isArray(group.hooks)) {
                throw new Error("hooks.json contains an invalid " + eventName + " Hook group");
            }
        });
    });
}

function install(configuration, executable, mode, managedExecutables) {
    validateTargetEventGroups(configuration);
    removeCodexBarHandlers(configuration, managedExecutables);
    const suffix = mode === "probe" ? " --probe" : "";
    const handler = {
        type: "command",
        command: shellQuote(executable) + " --codexbar-managed" + suffix,
        timeout: 5
    };

    ["UserPromptSubmit", "PermissionRequest", "Stop"].forEach(function (eventName) {
        if (!Array.isArray(configuration.hooks[eventName])) {
            configuration.hooks[eventName] = [];
        }
        const eventHandler = Object.assign({}, handler);
        const eventGroup = { hooks: [eventHandler] };
        configuration.hooks[eventName].push(eventGroup);
    });

    if (!Array.isArray(configuration.hooks.PreToolUse)) {
        configuration.hooks.PreToolUse = [];
    }
    const activityHandler = Object.assign({}, handler, { async: true });
    configuration.hooks.PreToolUse.push({
        matcher: "^(Read|read_file|Grep|Glob|rg|search|view_image|spawn_agent|send_input|send_message|wait_agent|resume_agent|close_agent|followup_task|interrupt_agent)$",
        hooks: [activityHandler]
    });
    const approvalMatcher = "^(Bash|apply_patch|Edit|Write|mcp__.+__.+)$";
    configuration.hooks.PreToolUse.push({
        matcher: approvalMatcher,
        hooks: [Object.assign({}, handler)]
    });
    configuration.hooks.PreToolUse.push({
        matcher: "^update_plan$",
        hooks: [Object.assign({}, handler)]
    });
    if (!Array.isArray(configuration.hooks.PostToolUse)) {
        configuration.hooks.PostToolUse = [];
    }
    configuration.hooks.PostToolUse.push({
        matcher: approvalMatcher,
        hooks: [Object.assign({}, handler)]
    });
}

function run(argv) {
    if (argv.length === 2 && argv[0] === "validate") {
        readConfiguration(argv[1]);
        return "";
    }
    if (argv.length < 4) {
        throw new Error("usage: hooks-config.js <install|remove> <hooks-file> <hook-executable> <inbox|probe> [previous-executable ...]");
    }
    const operation = argv[0];
    const configuration = readConfiguration(argv[1]);
    const executable = argv[2];
    const mode = argv[3];
    const managedExecutables = [executable].concat(argv.slice(4));

    if (operation === "install") {
        if (mode !== "inbox" && mode !== "probe") {
            throw new Error("Unknown install mode: " + mode);
        }
        install(configuration, executable, mode, managedExecutables);
    } else if (operation === "remove") {
        removeCodexBarHandlers(configuration, managedExecutables);
    } else {
        throw new Error("Unknown operation: " + operation);
    }

    return JSON.stringify(configuration, null, 2) + "\n";
}
